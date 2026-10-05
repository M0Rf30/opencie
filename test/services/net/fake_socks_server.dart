// SPDX-FileCopyrightText: 2026 Gianluca Boiano
// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What a client asked the fake proxy for.
class SocksSeen {
  SocksSeen({
    required this.version,
    required this.host,
    required this.port,
    required this.addressType,
    this.username,
    this.password,
    this.offeredMethods = const [],
  });

  final int version;

  /// Target as sent on the wire: domain name, or dotted/IPv6 text for IP
  /// address types.
  final String host;
  final int port;

  /// SOCKS5 ATYP (1/3/4); SOCKS4 uses 1 for a raw IP and 3 for 4a names.
  final int addressType;

  /// SOCKS5: RFC 1929 credentials; SOCKS4: user id (in [username]).
  final String? username;
  final String? password;
  final List<int> offeredMethods;
}

/// A minimal SOCKS4a/SOCKS5 server on loopback for tests.
///
/// It validates the wire format strictly (throwing into [errors] on
/// violations) and, on success, relays to `127.0.0.1:[relayPort] ?? port`
/// regardless of the requested host name, so tests can ask for an
/// unresolvable name and prove the name travelled to the proxy.
class FakeSocksServer {
  FakeSocksServer._(this._server, this.version, this._options);

  static Future<FakeSocksServer> start({
    required int version,
    String? requireUser,
    String? requirePassword,

    /// SOCKS5 REP / SOCKS4 CD to answer with instead of granting.
    int? replyCode,

    /// Redirect every granted connection to this local port.
    int? relayPort,

    /// Accept the TCP connection but never answer (handshake timeout).
    bool stall = false,

    /// Pick this SOCKS5 method regardless of the client offer.
    int? forceMethod,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeSocksServer._(
      server,
      version,
      _Options(
        requireUser: requireUser,
        requirePassword: requirePassword,
        replyCode: replyCode,
        relayPort: relayPort,
        stall: stall,
        forceMethod: forceMethod,
      ),
    );
    server.listen(fake._onClient);
    return fake;
  }

  final ServerSocket _server;
  final int version;
  final _Options _options;
  final List<Socket> _sockets = [];

  /// Successfully parsed requests, in arrival order.
  final List<SocksSeen> requests = [];

  /// Protocol violations or internal errors seen by the fake.
  final List<String> errors = [];

  /// Number of TCP connections accepted.
  int connections = 0;

  int get port => _server.port;

  Future<void> close() async {
    for (final s in _sockets) {
      s.destroy();
    }
    await _server.close();
  }

  void _onClient(Socket client) {
    connections++;
    _sockets.add(client);
    final reader = _Buf(client);
    // Intentional: a test client that hangs up early is not a fake failure.
    client.done.catchError((Object _) {});
    unawaited(
      (version == 5 ? _serve5(client, reader) : _serve4(client, reader))
          .catchError((Object e) {
            errors.add('$e');
            client.destroy();
          }),
    );
  }

  Future<void> _serve5(Socket c, _Buf r) async {
    final head = await r.read(2);
    if (head[0] != 5) throw 'bad SOCKS5 greeting version ${head[0]}';
    final methods = (await r.read(head[1])).toList();
    final needAuth = _options.requireUser != null;
    final int method;
    if (_options.forceMethod != null) {
      method = _options.forceMethod!;
    } else if (needAuth) {
      method = methods.contains(2) ? 2 : 0xFF;
    } else {
      method = methods.contains(0) ? 0 : 0xFF;
    }
    c.add([5, method]);
    await c.flush();
    if (method == 0xFF) {
      await c.close();
      return;
    }
    String? user;
    String? pass;
    if (method == 2) {
      final v = await r.read(1);
      if (v[0] != 1) throw 'bad RFC 1929 version ${v[0]}';
      final ulen = (await r.read(1))[0];
      user = utf8.decode(await r.read(ulen));
      final plen = (await r.read(1))[0];
      pass = utf8.decode(await r.read(plen));
      final ok =
          user == _options.requireUser &&
          pass == (_options.requirePassword ?? '');
      c.add([1, ok ? 0 : 1]);
      await c.flush();
      if (!ok) {
        await c.close();
        return;
      }
    }
    final req = await r.read(4);
    if (req[0] != 5 || req[1] != 1 || req[2] != 0) {
      throw 'bad SOCKS5 request ${req.toList()}';
    }
    final atyp = req[3];
    final String host;
    switch (atyp) {
      case 1:
        host = (await r.read(4)).join('.');
      case 3:
        final len = (await r.read(1))[0];
        host = ascii.decode(await r.read(len));
      case 4:
        host = InternetAddress.fromRawAddress(await r.read(16)).address;
      default:
        throw 'bad ATYP $atyp';
    }
    final pb = await r.read(2);
    final port = (pb[0] << 8) | pb[1];
    requests.add(
      SocksSeen(
        version: 5,
        host: host,
        port: port,
        addressType: atyp,
        username: user,
        password: pass,
        offeredMethods: methods,
      ),
    );
    if (_options.stall) return;
    if (_options.replyCode != null) {
      c.add([5, _options.replyCode!, 0, 1, 0, 0, 0, 0, 0, 0]);
      await c.flush();
      await c.close();
      return;
    }
    final upstream = await _dial(port);
    // Reply with a domain-type BND.ADDR to exercise the variable-length path.
    c.add([5, 0, 0, 3, 4, ...ascii.encode('bnd0'), 0x12, 0x34]);
    await c.flush();
    _relay(c, upstream, r);
  }

  Future<void> _serve4(Socket c, _Buf r) async {
    final head = await r.read(8);
    if (head[0] != 4 || head[1] != 1) throw 'bad SOCKS4 request $head';
    final port = (head[2] << 8) | head[3];
    final ip = head.sublist(4, 8);
    final user = await r.readUntilNul();
    final fourA = ip[0] == 0 && ip[1] == 0 && ip[2] == 0 && ip[3] != 0;
    final String host = fourA
        ? ascii.decode(await r.readUntilNul())
        : ip.join('.');
    requests.add(
      SocksSeen(
        version: 4,
        host: host,
        port: port,
        addressType: fourA ? 3 : 1,
        username: utf8.decode(user),
      ),
    );
    if (_options.stall) return;
    if (_options.replyCode != null) {
      c.add([0, _options.replyCode!, 0, 0, 0, 0, 0, 0]);
      await c.flush();
      await c.close();
      return;
    }
    final upstream = await _dial(port);
    c.add([0, 0x5A, 0x12, 0x34, 127, 0, 0, 1]);
    await c.flush();
    _relay(c, upstream, r);
  }

  Future<Socket> _dial(int requestedPort) => Socket.connect(
    InternetAddress.loopbackIPv4,
    _options.relayPort ?? requestedPort,
  );

  void _relay(Socket client, Socket upstream, _Buf r) {
    _sockets.add(upstream);
    upstream.done.catchError((Object _) {});
    // Bytes the client sent right behind the handshake.
    final rest = r.takePending();
    if (rest.isNotEmpty) upstream.add(rest);
    r.forward(upstream);
    upstream.listen(
      client.add,
      onDone: () => client.close(),
      onError: (Object _) => client.destroy(),
    );
  }
}

class _Options {
  _Options({
    this.requireUser,
    this.requirePassword,
    this.replyCode,
    this.relayPort,
    this.stall = false,
    this.forceMethod,
  });
  final String? requireUser;
  final String? requirePassword;
  final int? replyCode;
  final int? relayPort;
  final bool stall;
  final int? forceMethod;
}

/// Buffered reader that can switch to forwarding the rest of the stream.
class _Buf {
  _Buf(Stream<Uint8List> source) {
    _sub = source.listen(
      (d) {
        final t = _target;
        if (t != null) {
          t.add(d);
        } else {
          _bytes.add(d);
          _wake();
        }
      },
      onDone: () {
        _done = true;
        _target?.close();
        _wake();
      },
      onError: (Object _) {
        _done = true;
        _wake();
      },
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  Completer<void>? _waiter;
  bool _done = false;
  Socket? _target;

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<Uint8List> read(int n) async {
    while (_bytes.length < n) {
      if (_done) throw 'client closed mid-handshake';
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final all = _bytes.takeBytes();
    if (all.length > n) _bytes.add(Uint8List.sublistView(all, n));
    return Uint8List.sublistView(all, 0, n);
  }

  Future<Uint8List> readUntilNul() async {
    final out = BytesBuilder();
    while (true) {
      final b = (await read(1))[0];
      if (b == 0) return out.takeBytes();
      out.addByte(b);
    }
  }

  Uint8List takePending() => _bytes.takeBytes();

  void forward(Socket target) {
    _target = target;
    if (_done) target.close();
  }

  void cancel() => _sub.cancel();
}
