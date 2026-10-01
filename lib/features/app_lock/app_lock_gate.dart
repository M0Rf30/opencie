// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/app_lock/app_lock_controller.dart';
import '../../services/app_lock/app_lock_service.dart';
import '../../widgets/oc_mark.dart';
import 'app_lock_screen.dart';

/// Wraps the app shell and enforces the app lock.
///
/// - Hides the child (kept alive, not painted) while locked or not yet loaded.
/// - Meant to wrap the router's Navigator (MaterialApp.router `builder`), so
///   dialogs, sheets and pushed routes are all underneath the lock layer.
/// - Covers the window when the app becomes inactive (app switcher preview).
/// - Locks per the auto-lock timeout on background / minimize / blur, and on
///   desktop after an input-free period; Ctrl/Cmd+L locks immediately.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({
    required this.child,
    this.clock,
    this.isDesktop,
    super.key,
  });

  final Widget child;

  /// Injectable clock (tests).
  final DateTime Function()? clock;

  /// Override desktop detection (tests).
  final bool? isDesktop;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> {
  late final AutoLockPolicy _policy = AutoLockPolicy(clock: widget.clock);
  late final AppLifecycleListener _lifecycle;
  final ValueNotifier<bool> _covered = ValueNotifier(false);
  Timer? _idleTimer;

  bool get _desktop =>
      widget.isDesktop ??
      (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    HardwareKeyboard.instance.addHandler(_onKey);
    if (_desktop) {
      _idleTimer = Timer.periodic(
        const Duration(seconds: 5),
        (_) => _idleTick(),
      );
    }
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _lifecycle.dispose();
    HardwareKeyboard.instance.removeHandler(_onKey);
    _covered.dispose();
    super.dispose();
  }

  AppLockController get _ctrl => ref.read(appLockProvider.notifier);

  void _onLifecycle(AppLifecycleState s) {
    final st = ref.read(appLockProvider);
    if (!st.enabled || st.locked || _ctrl.biometricBusy) return;
    switch (s) {
      case AppLifecycleState.inactive:
        _policy.left(background: false);
        _covered.value = true;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _policy.left(background: true);
        _covered.value = true;
        if (_policy.shouldLockOnLeave(st.config.timeout, background: true)) {
          _ctrl.lock();
        }
      case AppLifecycleState.resumed:
        _covered.value = false;
        if (_policy.returned(st.config.timeout)) _ctrl.lock();
    }
  }

  bool _onKey(KeyEvent event) {
    final st = ref.read(appLockProvider);
    if (!st.enabled || st.locked) return false;
    _policy.activity();
    if (_desktop &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyL &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      _ctrl.lock();
      return true;
    }
    return false;
  }

  void _idleTick() {
    final st = ref.read(appLockProvider);
    if (!st.enabled || st.locked || _ctrl.biometricBusy) return;
    if (_covered.value) return; // unfocused: lifecycle logic applies
    if (_policy.idleExpired(st.config.timeout)) _ctrl.lock();
  }

  bool _shouldCover(AppLockState st) => !st.loaded || st.locked;

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(appLockProvider);
    final hidden = _shouldCover(st);
    ref.listen(appLockProvider, (prev, next) {
      if (prev?.locked != next.locked) _policy.activity();
    });
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _policy.activity(),
      onPointerMove: (_) => _policy.activity(),
      onPointerHover: (_) => _policy.activity(),
      onPointerSignal: (_) => _policy.activity(),
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          // The whole navigator (routes, dialogs, sheets, banners) lives in
          // this subtree: while locked it is kept alive but not painted,
          // hit-testable, focusable or exposed to accessibility services.
          ExcludeFocus(
            excluding: hidden,
            child: Offstage(offstage: hidden, child: widget.child),
          ),
          Positioned.fill(
            child: ValueListenableBuilder<bool>(
              valueListenable: _covered,
              builder: (context, covered, _) {
                if (st.locked) return const _LockLayer();
                if (covered || !st.loaded) return const _CoverLayer();
                return const SizedBox.shrink();
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Lock screen hosted in its own Navigator so it has an Overlay and can show
/// its own dialogs, independent of the (hidden) app navigator.
class _LockLayer extends StatelessWidget {
  const _LockLayer();

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      child: HeroControllerScope.none(
        child: Navigator(
          onGenerateRoute: (_) => PageRouteBuilder<void>(
            pageBuilder: (_, _, _) => const AppLockScreen(),
          ),
        ),
      ),
    );
  }
}

/// Opaque branded cover shown while inactive (app-switcher snapshot) or
/// before the lock state is known.
class _CoverLayer extends StatelessWidget {
  const _CoverLayer();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: const Center(child: OcMark(size: 56)),
    );
  }
}
