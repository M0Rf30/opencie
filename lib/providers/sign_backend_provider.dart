// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/sign/sign_backend.dart';
import '../services/sign/signature_upgrader.dart';

/// Provides the [SignBackend] used by the sign flow. Override in tests with a
/// fake to exercise signing without the native PKCS#11 library.
final signBackendProvider = Provider<SignBackend>((ref) => Pkcs11SignBackend());

/// Provides the post-sign [SignatureUpgrader] (timestamp + LTV). Override in
/// tests with a fake to avoid any network access.
final signatureUpgraderProvider = Provider<SignatureUpgrader>(
  (ref) => LtvSignatureUpgrader(),
);
