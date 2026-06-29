// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:pointycastle/pointycastle.dart' as pc;
import 'package:pointycastle/key_generators/rsa_key_generator.dart';

/// In-memory RSA key pair for the mock IdP.
class MockIdpKeyPair {
  MockIdpKeyPair._({
    required this.kid,
    required this.privateKey,
    required this.publicKey,
  });

  final String kid;
  final RSAPrivateKey privateKey;
  final RSAPublicKey publicKey;

  static MockIdpKeyPair generate() {
    final secureRandom = pc.SecureRandom('Fortuna')
      ..seed(
        pc.KeyParameter(
          Uint8List.fromList(
            List.generate(32, (_) => Random.secure().nextInt(256)),
          ),
        ),
      );
    final keyGen = RSAKeyGenerator()
      ..init(
        pc.ParametersWithRandom(
          pc.RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64),
          secureRandom,
        ),
      );
    final pair = keyGen.generateKeyPair();
    final priv = pair.privateKey;
    final pub = pair.publicKey;
    return MockIdpKeyPair._(
      kid: 'mock-key-1',
      privateKey: RSAPrivateKey.raw(priv),
      publicKey: RSAPublicKey.raw(pub),
    );
  }

  Map<String, dynamic> get jwk => {
    ...publicKey.toJWK(algorithm: JWTAlgorithm.RS256),
    'kid': 'mock-key-1',
    'use': 'sig',
  };
}
