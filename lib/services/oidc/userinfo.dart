// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Fetches the OIDC UserInfo endpoint.
class UserInfoClient {
  UserInfoClient({http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// GETs userinfo with the access token in the `Authorization: Bearer`
  /// header. Returns the parsed JSON claims map.
  Future<Map<String, Object?>> fetch(
    Uri userinfoEndpoint,
    String accessToken,
  ) async {
    final res = await _http.get(
      userinfoEndpoint,
      headers: {
        'Accept': 'application/json',
        'Authorization': 'Bearer $accessToken',
      },
    );
    if (res.statusCode != 200) {
      throw UserInfoException('UserInfo HTTP ${res.statusCode}: ${res.body}');
    }
    final body = json.decode(res.body);
    if (body is! Map<String, Object?>) {
      throw const UserInfoException('UserInfo body is not a JSON object');
    }
    return body;
  }
}

class UserInfoException implements Exception {
  const UserInfoException(this.message);
  final String message;
  @override
  String toString() => 'UserInfoException: $message';
}
