// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// SOCKS protocol flavour.
enum SocksVersion {
  /// SOCKS4, with the 4a extension (remote DNS) for host names.
  socks4,

  /// SOCKS5 (RFC 1928), no-auth or username/password (RFC 1929).
  socks5,
}

/// Failure while talking to a SOCKS proxy (connect, handshake, refusal).
///
/// Never carries the proxy password.
class SocksException implements Exception {
  SocksException(this.message);
  final String message;

  @override
  String toString() => 'SocksException: $message';
}

/// A SOCKS proxy endpoint. [toString] deliberately omits [password].
class SocksProxy {
  const SocksProxy({
    required this.version,
    required this.host,
    required this.port,
    this.username = '',
    this.password = '',
  });

  final SocksVersion version;
  final String host;
  final int port;
  final String username;
  final String password;

  @override
  String toString() => 'SocksProxy(${version.name} $host:$port)';
}

/// Signature of `HttpClient.connectionFactory`.
typedef SocksConnectionFactory =
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    );

/// Builds an `HttpClient.connectionFactory` that tunnels every connection
/// through [proxy].
///
/// `HttpClient` does **not** run TLS itself on sockets that come from a
/// connection factory (it only wraps them when it tunnels through an HTTP
/// proxy via `CONNECT`), so for `https` URLs the returned socket is already
/// secured with SNI and certificate validation against the target host.
///
/// The client must also use `findProxy = (_) => 'DIRECT'`, otherwise
/// `http_proxy`-style settings would reach the factory as `proxyHost`.
SocksConnectionFactory socksConnectionFactory(
  SocksProxy proxy, {
  Duration connectTimeout = const Duration(seconds: 15),
  Duration handshakeTimeout = const Duration(seconds: 15),
  SecurityContext? context,
}) {
  return (Uri url, String? proxyHost, int? proxyPort) async {
    final secure = url.isScheme('https');
    return startSocksConnect(
      proxy,
      targetHost: url.host,
      targetPort: url.port,
      secure: secure,
      connectTimeout: connectTimeout,
      handshakeTimeout: handshakeTimeout,
      context: context,
    );
  };
}

/// Connects to [targetHost]:[targetPort] through [proxy] and completes with
/// the tunnelled socket (TLS-secured when [secure]).
Future<Socket> connectViaSocks(
  SocksProxy proxy, {
  required String targetHost,
  required int targetPort,
  bool secure = false,
  Duration connectTimeout = const Duration(seconds: 15),
  Duration handshakeTimeout = const Duration(seconds: 15),
  SecurityContext? context,
}) => startSocksConnect(
  proxy,
  targetHost: targetHost,
  targetPort: targetPort,
  secure: secure,
  connectTimeout: connectTimeout,
  handshakeTimeout: handshakeTimeout,
  context: context,
).socket;

/// Like [connectViaSocks] but cancellable.
///
/// Every failure (including timeouts) completes `socket` with an error and
/// closes whatever socket was already opened. Timeouts surface as
/// [SocksException] because `HttpClient` asserts that a [TimeoutException]
/// only comes from its own `connectionTimeout`.
ConnectionTask<Socket> startSocksConnect(
  SocksProxy proxy, {
  required String targetHost,
  required int targetPort,
  bool secure = false,
  Duration connectTimeout = const Duration(seconds: 15),
  Duration handshakeTimeout = const Duration(seconds: 15),
  SecurityContext? context,
}) {
  final attempt = _Attempt();
  final future = _connect(
    attempt,
    proxy,
    targetHost,
    targetPort,
    secure,
    connectTimeout,
    handshakeTimeout,
    context,
  );
  return ConnectionTask.fromSocket(future, attempt.cancel);
}

class _Attempt {
  bool cancelled = false;
  ConnectionTask<Socket>? connecting;
  Socket? socket;

  void cancel() {
    cancelled = true;
    connecting?.cancel();
    socket?.destroy();
  }
}

Future<Socket> _connect(
  _Attempt attempt,
  SocksProxy proxy,
  String targetHost,
  int targetPort,
  bool secure,
  Duration connectTimeout,
  Duration handshakeTimeout,
  SecurityContext? context,
) async {
  Socket? socket;
  try {
    if (proxy.host.isEmpty || proxy.port <= 0 || proxy.port > 65535) {
      throw SocksException('invalid SOCKS proxy address');
    }
    if (targetHost.isEmpty || targetPort <= 0 || targetPort > 65535) {
      throw SocksException('invalid target address $targetHost:$targetPort');
    }
    final connecting = await Socket.startConnect(proxy.host, proxy.port);
    attempt.connecting = connecting;
    try {
      socket = await connecting.socket.timeout(connectTimeout);
    } on TimeoutException {
      connecting.cancel();
      throw SocksException(
        'timed out connecting to the SOCKS proxy ${proxy.host}:${proxy.port}',
      );
    } on SocketException catch (e) {
      throw SocksException(
        'cannot reach the SOCKS proxy ${proxy.host}:${proxy.port}: '
        '${e.message}',
      );
    }
    attempt.socket = socket;
    if (attempt.cancelled) throw SocksException('connection cancelled');
    socket.setOption(SocketOption.tcpNoDelay, true);
    // Intentional: write failures surface through flush()/read(); this only
    // stops an unobserved `done` error from escaping to the zone.
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));

    final reader = _Reader(socket);
    try {
      await _handshake(
        reader,
        socket,
        proxy,
        targetHost,
        targetPort,
      ).timeout(handshakeTimeout);
    } on TimeoutException {
      throw SocksException(
        'SOCKS handshake with ${proxy.host}:${proxy.port} timed out',
      );
    }
    if (attempt.cancelled) throw SocksException('connection cancelled');

    if (secure) {
      if (reader.hasPending) {
        throw SocksException('unexpected data from the proxy before TLS');
      }
      // The raw socket subscription is handed over to the TLS layer; our
      // stream-level subscription must not receive anything meanwhile.
      reader.pause();
      final secured = await SecureSocket.secure(
        socket,
        host: targetHost,
        context: context,
      ).timeout(handshakeTimeout);
      attempt.socket = secured;
      // Intentional: the handed-over subscription is already detached.
      unawaited(reader.cancel().catchError((_) {}));
      return secured;
    }
    return _SocksSocket(socket, reader.detach());
  } on TimeoutException {
    socket?.destroy();
    throw SocksException('timed out establishing the TLS session');
  } catch (_) {
    socket?.destroy();
    attempt.socket?.destroy();
    rethrow;
  }
}

Future<void> _handshake(
  _Reader reader,
  Socket socket,
  SocksProxy proxy,
  String host,
  int port,
) {
  switch (proxy.version) {
    case SocksVersion.socks4:
      return _socks4(reader, socket, proxy, host, port);
    case SocksVersion.socks5:
      return _socks5(reader, socket, proxy, host, port);
  }
}

String _hex(int v) => '0x${v.toRadixString(16).padLeft(2, '0')}';

// ---------------------------------------------------------------- SOCKS5

Future<void> _socks5(
  _Reader r,
  Socket socket,
  SocksProxy proxy,
  String host,
  int port,
) async {
  final useAuth = proxy.username.isNotEmpty;
  final user = utf8.encode(proxy.username);
  final pass = utf8.encode(proxy.password);
  if (useAuth && (user.length > 255 || pass.length > 255)) {
    throw SocksException('SOCKS5 username/password longer than 255 bytes');
  }
  final destination = _socks5Destination(host);

  // Greeting (RFC 1928 §3).
  socket.add([0x05, useAuth ? 2 : 1, 0x00, if (useAuth) 0x02]);
  await socket.flush();
  final choice = await r.read(2);
  if (choice[0] != 0x05) {
    throw SocksException(
      'not a SOCKS5 proxy (version byte ${_hex(choice[0])})',
    );
  }
  switch (choice[1]) {
    case 0x00:
      break;
    case 0x02:
      if (!useAuth) {
        throw SocksException(
          'the SOCKS5 proxy requires authentication but no credentials are '
          'configured',
        );
      }
      // Username/password sub-negotiation (RFC 1929).
      socket.add([0x01, user.length, ...user, pass.length, ...pass]);
      await socket.flush();
      final auth = await r.read(2);
      if (auth[1] != 0x00) {
        throw SocksException('SOCKS5 authentication failed');
      }
    case 0xFF:
      throw SocksException(
        useAuth
            ? 'the SOCKS5 proxy accepts none of the offered authentication '
                  'methods'
            : 'the SOCKS5 proxy requires authentication but no credentials '
                  'are configured',
      );
    default:
      throw SocksException(
        'the SOCKS5 proxy selected an unsupported authentication method '
        '(${_hex(choice[1])})',
      );
  }

  // CONNECT request (RFC 1928 §4).
  socket.add([
    0x05,
    0x01,
    0x00,
    ...destination,
    (port >> 8) & 0xFF,
    port & 0xFF,
  ]);
  await socket.flush();

  // Reply (RFC 1928 §6).
  final head = await r.read(4);
  if (head[0] != 0x05) {
    throw SocksException(
      'invalid SOCKS5 reply (version byte ${_hex(head[0])})',
    );
  }
  if (head[1] != 0x00) {
    throw SocksException(_socks5ReplyMessage(head[1], host, port));
  }
  final int boundLength;
  switch (head[3]) {
    case 0x01:
      boundLength = 4;
    case 0x04:
      boundLength = 16;
    case 0x03:
      boundLength = (await r.read(1))[0];
    default:
      throw SocksException(
        'invalid SOCKS5 reply (address type ${_hex(head[3])})',
      );
  }
  await r.read(boundLength + 2);
}

List<int> _socks5Destination(String host) {
  final ip = InternetAddress.tryParse(host);
  if (ip != null && ip.type == InternetAddressType.IPv4) {
    return [0x01, ...ip.rawAddress];
  }
  if (ip != null && ip.type == InternetAddressType.IPv6) {
    return [0x04, ...ip.rawAddress];
  }
  final name = ascii.encode(_asciiHost(host));
  if (name.isEmpty || name.length > 255) {
    throw SocksException('invalid target host name');
  }
  return [0x03, name.length, ...name];
}

String _asciiHost(String host) {
  if (host.codeUnits.any((unit) => unit > 0x7F)) {
    throw SocksException('non-ASCII target host name (use the A-label form)');
  }
  return host;
}

String _socks5ReplyMessage(int code, String host, int port) {
  final target = '$host:$port';
  switch (code) {
    case 0x01:
      return 'SOCKS5 proxy: general failure connecting to $target';
    case 0x02:
      return 'SOCKS5 proxy: connection to $target not allowed by ruleset';
    case 0x03:
      return 'SOCKS5 proxy: network unreachable for $target';
    case 0x04:
      return 'SOCKS5 proxy: host unreachable ($target)';
    case 0x05:
      return 'SOCKS5 proxy: connection refused by $target';
    case 0x06:
      return 'SOCKS5 proxy: TTL expired reaching $target';
    case 0x07:
      return 'SOCKS5 proxy: CONNECT command not supported';
    case 0x08:
      return 'SOCKS5 proxy: address type not supported';
    default:
      return 'SOCKS5 proxy: connection to $target failed (${_hex(code)})';
  }
}

// --------------------------------------------------------------- SOCKS4(a)

Future<void> _socks4(
  _Reader r,
  Socket socket,
  SocksProxy proxy,
  String host,
  int port,
) async {
  final userId = utf8.encode(proxy.username);
  if (userId.contains(0)) {
    throw SocksException('SOCKS4 user id must not contain NUL');
  }
  final ip = InternetAddress.tryParse(host);
  final List<int> address;
  List<int> hostBytes = const [];
  if (ip != null && ip.type == InternetAddressType.IPv4) {
    address = ip.rawAddress;
  } else if (ip != null) {
    throw SocksException('SOCKS4 cannot reach IPv6 addresses');
  } else {
    // SOCKS4a: 0.0.0.x (x != 0) tells the proxy to resolve the name.
    address = const [0, 0, 0, 1];
    final name = ascii.encode(_asciiHost(host));
    if (name.isEmpty || name.length > 255) {
      throw SocksException('invalid target host name');
    }
    hostBytes = [...name, 0];
  }
  socket.add([
    0x04,
    0x01,
    (port >> 8) & 0xFF,
    port & 0xFF,
    ...address,
    ...userId,
    0x00,
    ...hostBytes,
  ]);
  await socket.flush();

  final reply = await r.read(8);
  if (reply[0] != 0x00 && reply[0] != 0x04) {
    throw SocksException(
      'not a SOCKS4 proxy (reply version ${_hex(reply[0])})',
    );
  }
  switch (reply[1]) {
    case 0x5A:
      return;
    case 0x5B:
      throw SocksException('SOCKS4 proxy: request rejected or failed');
    case 0x5C:
      throw SocksException(
        'SOCKS4 proxy: rejected, cannot reach the identd service',
      );
    case 0x5D:
      throw SocksException(
        'SOCKS4 proxy: rejected, identd user id does not match',
      );
    default:
      throw SocksException(
        'SOCKS4 proxy: unknown reply code ${_hex(reply[1])}',
      );
  }
}

// ---------------------------------------------------------------- plumbing

/// Single subscription over the socket: buffers handshake bytes, then hands
/// the stream over (via [detach]) without losing or reordering data.
class _Reader {
  _Reader(Stream<Uint8List> source) {
    _sub = source.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  StreamController<Uint8List>? _out;
  Completer<void>? _waiter;
  Object? _error;
  bool _done = false;

  bool get hasPending => _buffer.isNotEmpty;

  void pause() => _sub.pause();

  Future<void> cancel() => _sub.cancel();

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void _onData(Uint8List data) {
    final out = _out;
    if (out != null) {
      out.add(data);
    } else {
      _buffer.add(data);
      _wake();
    }
  }

  void _onError(Object error, StackTrace stack) {
    final out = _out;
    if (out != null) {
      out.addError(error, stack);
    } else {
      _error ??= error;
      _wake();
    }
  }

  void _onDone() {
    _done = true;
    final out = _out;
    if (out != null) {
      out.close();
    } else {
      _wake();
    }
  }

  /// Reads exactly [n] bytes. Cancellation/timeout are handled by the caller
  /// (the socket is destroyed, which wakes this loop with an error).
  Future<Uint8List> read(int n) async {
    while (_buffer.length < n) {
      final error = _error;
      if (error != null) {
        throw SocksException(
          error is SocketException
              ? 'connection to the proxy failed: ${error.message}'
              : 'connection to the proxy failed',
        );
      }
      if (_done) {
        throw SocksException('the proxy closed the connection unexpectedly');
      }
      final waiter = _waiter = Completer<void>();
      await waiter.future;
    }
    final all = _buffer.takeBytes();
    if (all.length > n) _buffer.add(Uint8List.sublistView(all, n));
    return Uint8List.sublistView(all, 0, n);
  }

  /// Switches to pass-through mode and returns the remaining byte stream,
  /// starting with anything already buffered beyond the handshake.
  Stream<Uint8List> detach() {
    final out = StreamController<Uint8List>(
      onPause: _sub.pause,
      onResume: _sub.resume,
      onCancel: _sub.cancel,
    );
    if (_buffer.isNotEmpty) out.add(_buffer.takeBytes());
    final error = _error;
    if (error != null) out.addError(error);
    if (_done) out.close();
    _out = out;
    return out.stream;
  }
}

/// Plain-TCP tunnel handed to `HttpClient`: reads come from the reader's
/// pass-through stream, writes go straight to the underlying socket.
class _SocksSocket extends Stream<Uint8List> implements Socket {
  _SocksSocket(this._socket, this._stream);

  final Socket _socket;
  final Stream<Uint8List> _stream;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  Encoding get encoding => _socket.encoding;

  @override
  set encoding(Encoding value) => _socket.encoding = value;

  @override
  void add(List<int> data) => _socket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);

  @override
  Future<dynamic> addStream(Stream<List<int>> stream) =>
      _socket.addStream(stream);

  @override
  Future<dynamic> close() => _socket.close();

  @override
  Future<dynamic> get done => _socket.done;

  @override
  void destroy() => _socket.destroy();

  @override
  Future<dynamic> flush() => _socket.flush();

  @override
  void write(Object? object) => _socket.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _socket.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _socket.writeln(object);

  @override
  InternetAddress get address => _socket.address;

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;

  @override
  int get port => _socket.port;

  @override
  int get remotePort => _socket.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
}
