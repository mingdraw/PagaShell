import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:pagashell/presentation/components/app_dialog.dart';
import 'package:pagashell/presentation/components/app_text_form_field.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import 'support/shadcn_test_app.dart';

void main() {
  tearDown(Get.reset);

  testWidgets('滚动弹框首尾输入框的焦点边框完整可见，且避开滚动条', (tester) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final first = TextEditingController(text: 'First');
    final last = TextEditingController(text: 'Last');
    addTearDown(first.dispose);
    addTearDown(last.dispose);
    await tester.pumpWidget(
      ShadcnTestApp(
        home: AppDialog(
          title: const Text('Edit service'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppTextFormField(
                key: const ValueKey('first-input'),
                controller: first,
                autofocus: true,
              ),
              const SizedBox(height: 600),
              AppTextFormField(
                key: const ValueKey('last-input'),
                controller: last,
              ),
            ],
          ),
          actions: [
            shadcn.OutlineButton(onPressed: () {}, child: const Text('Cancel')),
            shadcn.PrimaryButton(onPressed: () {}, child: const Text('Save')),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scrollView = find.descendant(
      of: find.byType(AppDialog),
      matching: find.byType(SingleChildScrollView),
    );
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: scrollView,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .first,
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));

    void expectFocusVisible(String key) {
      final outline = find
          .descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(shadcn.FocusOutline),
          )
          .first;
      expect(tester.widget<shadcn.FocusOutline>(outline).focused, isTrue);
      final viewport = tester.getRect(scrollView);
      // shadcn FocusOutline 默认向输入框边界外延伸 3px。
      final ring = tester.getRect(outline).inflate(3);
      final theme = shadcn.Theme.of(tester.element(outline));
      final scrollbarWidth =
          (7 + theme.density.baseGap * 0.125) * theme.scaling;
      expect(ring.left, greaterThanOrEqualTo(viewport.left));
      expect(ring.top, greaterThanOrEqualTo(viewport.top));
      expect(ring.right, lessThanOrEqualTo(viewport.right - scrollbarWidth));
      expect(ring.bottom, lessThanOrEqualTo(viewport.bottom));
      expect(find.text('Save').hitTestable(), findsOneWidget);
      expect(find.text('Cancel').hitTestable(), findsOneWidget);
    }

    expectFocusVisible('first-input');
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('last-input')),
        matching: find.byType(shadcn.TextField),
      ),
    );
    await tester.pumpAndSettle();
    expectFocusVisible('last-input');
    expect(tester.takeException(), isNull);
  });
}
