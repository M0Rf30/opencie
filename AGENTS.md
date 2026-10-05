<!--
SPDX-FileCopyrightText: 2026 Gianluca Boiano
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Repository Guidelines

## Project Overview

OpenCIE is a Flutter desktop + Android app for the Italian electronic identity card (CIE 3.0, contact and contactless). It enrols cards, signs documents (PAdES `.pdf`, CAdES `.p7m`, XAdES `.xml`), verifies signatures, adds RFC 3161 timestamps, and offers phone-as-reader **handoff**: a desktop starts a signature and an NFC Android phone does the card work. All card crypto goes through the native library **libopencie-pkcs11**, which lives in a separate repo (`M0Rf30/opencie-pkcs11`), via `dart:ffi`. Targets are Linux (x64/arm64, Flatpak), Windows, macOS (arm64) and Android. iOS is not supported. Bundle ID: `io.github.m0rf30.opencie`.

## Architecture & Data Flow

- **Bootstrap:** `lib/main.dart` (`pdfrxFlutterInitialize` → `ProviderScope`) → `lib/app.dart` `OpenCieApp`. It waits for `settingsProvider.isLoaded`, then builds the router **once**: initial route `/cie` when no card is enrolled, else `/sign`. It applies `uiScale` and wraps everything in `AppLockGate`. Keep the startup path free of native and network calls, because `test/widget_test.dart` pumps the real app.
- **Routing:** everything is in `lib/router/app_router.dart` (go_router). `StatefulShellRoute.indexedStack` has 5 branches: `/sign`, `/verify`, `/timestamp`, `/cie`, `/settings`. The branch keys come from `List.generate(5)`, so a new tab means changing that count.
- **State:** `flutter_riverpod` 3 with **hand-written** `Notifier`/`NotifierProvider`/`Provider`. There is no `@riverpod`, `part` or `build_runner`; **do not introduce codegen**. Pages are large `ConsumerStatefulWidget`s. Page-local progress uses `ValueNotifier` records such as `(bool, double, String)`.
- **FFI layer (`lib/ffi/`):**
  - `opencie_bindings.dart`: **hand-maintained** `FooNative`/`FooDart` typedef pairs that mirror `include/opencie/cie_ext.h` from the native repo (no ffigen). Update the header comment when you bump the native lib.
  - `opencie_pkcs11.dart`: the `OpenCiePkcs11.instance` singleton. `DynamicLibrary.open` uses `libopencie-pkcs11.so` / `.dylib`, or `opencie-pkcs11.dll` on Windows (the Windows CMake renames it).
  - **Blocking calls run in `Isolate.run` and reopen the lib inside the isolate.** These are `enable`, `sign`, `verify`, `getCertificate`, `readDgs`, `readDgsCan`, `timestamp`, `extractP7m` and the PIN ops. Quick queries (`readerCount`, `isEnabled`) stay on the main isolate.
  - Progress callbacks are `Pointer.fromFunction` on **top-level/static functions that never throw**. They send `[percent, message]` through `_withProgress()`.
  - Zero PIN/PUK buffers with `_wipeUtf8()` before `calloc.free`. Free native-owned buffers with `cie_free`.
- **Error model:** calls return results, not exceptions. `CieResult` holds the CK_RV `returnValue`, `remainingAttempts`, `statusWord` and `nativeErrorKind`. Classify with `classifyCieError()` and localize with `cieErrorMessage()` (`lib/services/cie_error.dart`). CK_RV constants are in `lib/core/constants/app_constants.dart`. Exception: `verify()` throws, and its failure test is `rv != cie_get_sign_count()` (`cieVerifyFailed`). Feature exceptions are `OidcException`, `TspException`, `PadesException` and `SecureStoreException`.
- **Main flows:**
  - **Sign** (`features/sign/sign_page.dart`): PIN dialog → Android `NfcService.startSession`, or PC/SC directly on desktop → `ref.read(signBackendProvider).sign(...)`. `SignBackend` is abstract; production is `Pkcs11SignBackend` in `services/sign/`. `PinThrottle` adds a UI back-off on top of the card's own counter. `pan` is intentionally `''` (see `settings_provider.dart`).
  - **Timestamp/LTV upgrade** (`services/sign/signature_upgrader.dart`, `signatureUpgraderProvider`): runs after a successful native sign when `SignatureOptions.timestampRequested` (toggle seeded from `settings.alwaysTimestamp`). PAdES gets a DSS (certs + OCSP/CRL) then a DocTimeStamp; CAdES gets a signature timestamp, revocation values and an archive timestamp. XAdES is unsupported, so its toggle is disabled. Revocation order follows `settings.validationType`; the TSA and proxy come from settings. **It never throws and always keeps the signed file**: failures become `timestampFailed` / `revocationUnavailable` warnings in the result dialog or batch item. The file is replaced via temp file + rename.
  - **Batch** (`services/batch_sign/`): files are signed one at a time and the result is a `Stream<BatchSignState>`. A wrong or locked PIN aborts the batch. Any other error fails only that file. Each file is upgraded as above when `alwaysTimestamp` is on.
  - **Enrol and chip read** (`features/cie_management/`, `services/cie_chip_reader.dart`): `enable` → `getCertificate` → `readDgsCan`, which tries PACE-CAN first and falls back to the PIN. Cards are stored in `SecureStore`.
  - **Handoff** (`services/handoff/`, `features/handoff/`, user doc `docs/HANDOFF.md`): QR-paired WebRTC data channel with X25519 + ChaCha20-Poly1305 and a 4-word SAS. Protocol v2 uses 16 KiB chunks and a 50 MiB limit. The phone signs the real file through `OpenCiePkcs11` directly, **bypassing `SignBackend`**. The desktop verifies before saving.
  - **LTV** (`services/ltv/**`): pure-Dart PAdES/CAdES LT/LTA, OCSP, CRL, TSP, DER and an incremental PDF writer, consumed by the upgrader above. Limits: PAdES supports classic xref tables only.
  - **OIDC/SPID** (`services/oidc/**`): a PKCE/SPID library with no UI (there are no login routes). `services/oidc/as/` is a shelf-based `MockIdpServer` used **only by tests**. OpenCIE does *not* do website login, so don't advertise login in UI strings or docs.
- **Persistence:** `SettingsNotifier` keeps `opencie_settings` JSON in SharedPreferences. Secrets (enrolled cards, TSA/proxy passwords) go in `SecureStore`, which throws `SecureStoreException`: `null` means absent, an exception means the store is unreachable. To update settings: `ref.read(settingsProvider.notifier).update((s) => s.copyWith(...))`. Removed keys in old JSON are ignored on load, so drop a setting by deleting its field, JSON read/write and UI row; no migration is needed. Don't keep settings that nothing consumes.

## Key Directories

- `lib/features/<name>/`: pages plus `widgets/` and `utils/`. Names: `app_lock`, `cie_management`, `handoff`, `settings`, `sign`, `timestamp`, `verify`.
- `lib/services/`: non-UI logic (sign, batch_sign, handoff, ltv, oidc, app_lock, NFC, secure store, PIN throttle, update checker).
- `lib/providers/`: global Riverpod state (settings, recent files, batch sign, sign backend).
- `lib/core/`: `constants/`, `l10n/` (ARB files plus `app_localizations_ext.dart`), and `theme/` (`AppTheme`, `ColorSchemes`, `OcColors`).
- `lib/widgets/`: shared `Oc*` widgets (`OcPage`, `OcGradientButton`, `OcFileTile`, …) plus `PinEntryDialog` and `NfcCardDialog`. Use these rather than raw widgets.
- `test/`: mirrors `lib/`. `scripts/`: native-lib fetching. `tools/`: icon rendering, local Flatpak build. `flatpak/`: local, `ci/` and `flathub/` manifests. `installer/`: Inno Setup (`opencie.iss`).
- `docs/`: `HANDOFF.md` is current. `LTV_*`, `CADES_LTA_IMPLEMENTATION.md`, `INDEX.md` and `research/` are **historical**. Treat the code as the source of truth.

## Development Commands

```bash
flutter pub get                       # also runs gen-l10n (generated l10n files are gitignored)
flutter analyze                       # must be clean (CI gate)
dart format .                         # CI runs: dart format --output=none --set-exit-if-changed .
flutter test --exclude-tags network   # what CI runs (add --coverage for lcov)
flutter run -d linux                  # or: flutter devices / -d <id>
flutter build {linux|windows|macos|apk|appbundle} --release
```

Get the native lib locally. Releases are checksum-verified and need `gh`.

```bash
./scripts/fetch-pkcs11.sh 1.3.2 '*linux-x86_64.so' libopencie-pkcs11.so   # repo root is auto-picked by linux/CMakeLists.txt
export OPENCIE_PKCS11_LIB=/abs/path/libopencie-pkcs11.so                 # alternative (also for Windows .dll / macOS .dylib)
./scripts/sync-jnilibs.sh 1.3.2       # Android: fills android/app/src/main/jniLibs/<abi>/
./tools/flatpak-build.sh && flatpak run io.github.m0rf30.opencie
```

Hardware: Android needs NFC. Desktop needs a PC/SC reader; on Linux run `sudo systemctl enable --now pcscd.socket`. Native logs go to `~/.CIEPKI/`.

## Code Conventions & Common Patterns

- **Licensing (REUSE 3.3):** every file needs `SPDX-FileCopyrightText: <year> Gianluca Boiano` and `SPDX-License-Identifier: GPL-3.0-or-later` as two adjacent lines in its native comment syntax (Dart: `//` at the top; Markdown: `<!-- -->`; after any shebang or `<?xml?>`). Exceptions: the AppStream metainfo files are `CC0-1.0` (matching `<metadata_license>`), and fonts are `OFL-1.1`. Files that can't carry comments (JSON, ARB, images, Xcode-managed or Flutter-generated files) are covered in `REUSE.toml`. License texts live in `LICENSES/`. `reuse lint` must pass.
- Files are `snake_case.dart`: `*_page.dart`, `*_dialog.dart`, `*_service.dart`/`*_client.dart`, `*_provider.dart`. Classes use `FooNotifier` and providers use `fooProvider`.
- In `lib/`, use **relative imports** (`../../services/...`). Tests import `package:opencie/...`.
- Models are plain classes with hand-written `copyWith`/`toJson`/`fromJson`; there is no freezed or json_serializable. Nullable fields are cleared with an `_unset` sentinel (`AppSettings.copyWith`).
- Lints: `flutter_lints` with `strict-casts`, `strict-inference` and `strict-raw-types`. Formatting uses the default 80 columns.
- Logging is `debugPrint('Class.method: msg ($e)')` only. Never log PINs, PUKs or CANs.
- UI errors are floating SnackBars in the error colour. Check `if (!mounted) return;` after every `await`. Every empty `catch (_)` needs an `// Intentional:` comment.
- Set re-entry guards (such as `_isSigning`) synchronously, before the first `await`.
- Platform branches use inline `Platform.isAndroid`. NFC is Android-only; the MethodChannel is `io.github.m0rf30.opencie/nfc`.
- **l10n:** add each key to **both** `lib/core/l10n/intl_en.arb` (the template, which also declares placeholders) and `intl_it.arb`. Keys are camelCase with a feature prefix: `signTitle`, `cieEnrolDialogTitle`, `errCardNotFound`. Use `AppLocalizations.of(context)`. Messages should state plainly what is wrong. `AppSettings.languageCode` (`null` = system, `it`, `en`) is passed to `MaterialApp.locale`.
- Test seams: abstract interfaces (`SignBackend`, `HandoffTransport`), constructor-injected `http.Client`, and `@visibleForTesting` hooks (`OpenCiePkcs11.debugWatchReaders`, `PinThrottle.clock`, `*Session.forTesting`, `OidcRedirectListener.testing`).
- Commits follow Conventional Commits with a scope: `fix(ffi): …`, `feat(sign): …`, `ci: …`, `chore(release): 0.5.1, fetch libopencie-pkcs11 1.3.2`. Reference issues as `(#34)`. DCO applies: `git commit -s`. Branches are named `type/topic`.

## Important Files

- `lib/main.dart`, `lib/app.dart`, `lib/router/app_router.dart`: entry and navigation.
- `lib/ffi/opencie_pkcs11.dart`, `lib/ffi/opencie_bindings.dart`: native boundary.
- `lib/providers/settings_provider.dart`, `lib/services/secure_store.dart`: persistence.
- `lib/services/sign/sign_backend.dart`, `lib/services/cie_error.dart`, `lib/core/constants/app_constants.dart`.
- `pubspec.yaml` (`version: X.Y.Z+N`), `analysis_options.yaml`, `l10n.yaml`, `dart_test.yaml`.
- `.github/workflows/main.yml`: pins `OPENCIE_PKCS11_VERSION` (single source for every platform) and Flutter `3.47.0`, which appears in several places.
- `linux/CMakeLists.txt`, `windows/CMakeLists.txt` (MSVC `/W4 /WX`), `android/app/build.gradle.kts` (minSdk 24, NDK pin, signing via gitignored `android/key.properties`).
- `flatpak/*.metainfo.xml` and `flatpak/flathub/*.metainfo.xml`: **both** need identical `<release>` entries.

## Runtime/Tooling Preferences

- Dart `^3.11.1`, Flutter stable (CI pins 3.47.0). `.fvmrc` floats on `stable`; `fvm flutter …` works too.
- `pubspec.lock` and all `*.so` files are gitignored, so the native lib is never committed. The exception is the tracked `libc++_shared.so`.
- Shell scripts run on macOS CI and must stay **bash 3.2 compatible** (no `mapfile`, no `declare -A`, no `${var,,}`).
- macOS builds are ad-hoc signed and not notarized, on purpose. The Windows installer is unsigned. Both read their version from pubspec.
- **Release:**
  1. Commit `chore(release): X.Y.Z[, fetch libopencie-pkcs11 A.B.C]`. It bumps the pubspec version (X.Y.Z and the +N build number), `OPENCIE_PKCS11_VERSION`, and the release entries in both metainfo files.
  2. Tag `vX.Y.Z`. CI checks that the tag matches pubspec and metainfo, then publishes.
  3. Commit `chore(flathub): bundle vX.Y.Z`, updating the two tarball URLs and sha256 values in `flatpak/flathub/io.github.m0rf30.opencie.yml`.

## Testing & QA

- Tests use `flutter_test` (a few use `package:test`). There is **no mocktail or mockito**: fakes are hand-written per file, e.g. `_FakeSignBackend implements SignBackend`. Shared fakes and fixtures live in non-`_test.dart` files: `test/handoff/fake_transport.dart`, `test/ltv/pades/synthetic_pdf.dart`, `test/ltv/cades/synthetic_cades.dart`, `test/services/sign/upgrade_test_support.dart`. Never import another `*_test.dart` file.
- HTTP is faked with `MockClient` from `package:http/testing.dart`. OIDC/SPID end-to-end tests run the in-app `MockIdpServer` over loopback, with no external network.
- **Tests never load libopencie-pkcs11**, and the CI test job has no native lib. Inject callbacks instead, e.g. `readDgs:` returning `CieReadDgsResult(returnValue: AppConstants.ckrOk, …)`.
- Provider overrides: `signBackendProvider.overrideWithValue(fake)` and `signatureUpgraderProvider.overrideWithValue(fake)`, with `UncontrolledProviderScope(container: …)` and `addTearDown(container.dispose)`.
- Storage fixtures: `SharedPreferences.setMockInitialValues({'opencie_settings': jsonEncode({...})})`, `FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({})`, and `PackageInfo.setMockInitialValues(...)`. Widget tests wrap pages in `MaterialApp` with the `AppLocalizations` delegates.
- Use `group('Feature', …)` with sentence-style test names. Ticket tags like `(OC-36)` are fine.
- Running tests:
  - one file: `flutter test test/services/pin_throttle_test.dart`
  - one test by name: `--plain-name 'classifyCieError'`
- **Tags** (`dart_test.yaml`):
  - `network`: excluded in CI and skipped unless `OPENCIE_NETWORK_TESTS=1`. Run `OPENCIE_NETWORK_TESTS=1 flutter test --tags network`.
  - `screenshots`: regenerates `docs/screenshots/*.png` from fake data. Run `OPENCIE_SCREENSHOTS=1 flutter test --tags screenshots test/screenshots` from the repo root with `FLUTTER_ROOT` set.
- Coverage is collected (`coverage/lcov.info`) with no threshold. Before pushing, run analyze, the format check and the tests. Fixtures must be synthetic: no real personal or card data.
