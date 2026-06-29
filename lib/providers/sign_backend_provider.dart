// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/sign/sign_backend.dart';

/// Provides the [SignBackend] used by the sign flow. Override in tests with a
/// fake to exercise signing without the native PKCS#11 library.
final signBackendProvider = Provider<SignBackend>((ref) => Pkcs11SignBackend());
