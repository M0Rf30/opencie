// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencie/features/sign/widgets/signature_box_overlay.dart';

void main() {
  const page = Size(400, 600);
  // 100,200 .. 220,260 on screen => x=.25, bottom=(600-260)/600
  const frac = Rect.fromLTWH(0.25, 340 / 600, 0.3, 0.1);
  Rect? committed;
  var commits = 0;

  Future<void> pump(WidgetTester tester) async {
    committed = null;
    commits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox.fromSize(
              size: page,
              child: SignatureBoxOverlay(
                pageSize: page,
                fraction: frac,
                imageData: null,
                imageAspect: null,
                lockAspect: false,
                semanticsLabel: 'area',
                signHereLabel: 'sign',
                onCommit: (r) {
                  committed = r;
                  commits++;
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Offset origin(WidgetTester t) =>
      t.getTopLeft(find.byType(SignatureBoxOverlay));

  testWidgets('drag inside moves and commits once on end', (tester) async {
    await pump(tester);
    final g = await tester.startGesture(
      origin(tester) + const Offset(160, 230),
    );
    await g.moveBy(const Offset(40, 0));
    await g.moveBy(const Offset(10, 10));
    expect(commits, 0);
    await g.up();
    expect(commits, 1);
    expect(committed!.left, closeTo(frac.left + 50 / 400, 1e-6));
    expect(committed!.width, closeTo(frac.width, 1e-6));
    expect(committed!.top, closeTo(frac.top - 10 / 600, 1e-6));
  });

  testWidgets('drag on corner handle resizes, anchor kept', (tester) async {
    await pump(tester);
    // bottom-right corner (220,260)
    final g = await tester.startGesture(
      origin(tester) + const Offset(224, 264),
    );
    await g.moveTo(origin(tester) + const Offset(320, 300));
    await g.up();
    expect(commits, 1);
    expect(committed!.left, closeTo(0.25, 1e-6));
    expect(committed!.width, closeTo(220 / 400, 1e-6));
    expect(committed!.height, closeTo(100 / 600, 1e-6));
  });

  testWidgets('drag on empty area draws up-left from the start point', (
    tester,
  ) async {
    await pump(tester);
    final g = await tester.startGesture(
      origin(tester) + const Offset(300, 400),
    );
    await g.moveTo(origin(tester) + const Offset(250, 350));
    await g.moveTo(origin(tester) + const Offset(200, 300));
    await g.up();
    expect(commits, 1);
    expect(committed!.left, closeTo(200 / 400, 1e-6));
    expect(committed!.width, closeTo(100 / 400, 1e-6));
    expect(committed!.height, closeTo(100 / 600, 1e-6));
    expect(committed!.top, closeTo(1 - 400 / 600, 1e-6));
  });

  testWidgets('tap on empty area centres the box there', (tester) async {
    await pump(tester);
    await tester.tapAt(origin(tester) + const Offset(300, 400));
    expect(commits, 1);
    expect(committed!.width, closeTo(frac.width, 1e-6));
    expect(committed!.left + committed!.width / 2, closeTo(300 / 400, 1e-6));
  });

  testWidgets('arrow keys nudge, shift = 10px', (tester) async {
    await pump(tester);
    await tester.tapAt(origin(tester) + const Offset(160, 230));
    committed = null;
    commits = 0;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(commits, 1);
    expect(committed!.left, closeTo(frac.left + 1 / 400, 1e-6));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(commits, 2);
    // up on screen = larger bottom-origin y
    expect(committed!.top, closeTo(frac.top + 10 / 600, 1e-6));
  });
}
