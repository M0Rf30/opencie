// SPDX-License-Identifier: GPL-3.0-or-later

/// Proxy configuration mode.
enum ProxyMode { none, system, manual }

/// Proxy protocol type.
enum ProxyType { http, socks4, socks5 }

/// Network proxy configuration.
class ProxyConfig {
  const ProxyConfig({
    this.mode = ProxyMode.none,
    this.type = ProxyType.http,
    this.host = '',
    this.port = 0,
    this.username = '',
    this.password = '',
  });

  final ProxyMode mode;
  final ProxyType type;
  final String host;
  final int port;
  final String username;
  final String password;

  bool get isConfigured => mode == ProxyMode.manual && host.isNotEmpty;

  /// Returns "host:port" or null if not configured.
  String? get address => isConfigured ? '$host:$port' : null;

  /// Returns "user:pass" for proxy auth, or null.
  String? get userPass => username.isNotEmpty ? '$username:$password' : null;

  ProxyConfig copyWith({
    ProxyMode? mode,
    ProxyType? type,
    String? host,
    int? port,
    String? username,
    String? password,
  }) {
    return ProxyConfig(
      mode: mode ?? this.mode,
      type: type ?? this.type,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'type': type.name,
    'host': host,
    'port': port,
    'username': username,
    'password': password,
  };

  factory ProxyConfig.fromJson(Map<String, dynamic> json) => ProxyConfig(
    mode: ProxyMode.values.byName(json['mode'] as String? ?? 'none'),
    type: ProxyType.values.byName(json['type'] as String? ?? 'http'),
    host: json['host'] as String? ?? '',
    port: json['port'] as int? ?? 0,
    username: json['username'] as String? ?? '',
    password: json['password'] as String? ?? '',
  );
}
