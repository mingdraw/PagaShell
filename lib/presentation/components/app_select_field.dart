import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

class AppSelectOption<T> {
  const AppSelectOption({required this.value, required this.child});
  final T value;
  final Widget child;
}

/// shadcn Select 与 Flutter 核心 Form 校验互通。
class AppSelectField<T> extends FormField<T> {
  AppSelectField({
    required String label,
    required List<AppSelectOption<T>> items,
    required ValueChanged<T?>? onChanged,
    bool canUnselect = false,
    WidgetBuilder? popupBuilder,
    super.initialValue,
    super.validator,
    super.key,
  }) : super(
         builder: (state) {
           final colors = shadcn.Theme.of(state.context).colorScheme;
           return Column(
             crossAxisAlignment: CrossAxisAlignment.stretch,
             children: [
               Text(
                 label,
                 style: const TextStyle(
                   fontSize: 13,
                   fontWeight: FontWeight.w500,
                 ),
               ),
               const SizedBox(height: 6),
               shadcn.OverlayAnchor(
                 anchor: state,
                 child: shadcn.Select<T>(
                   theme: shadcn.SelectTheme(
                     adaptiveOverlay: false,
                     overlayConfiguration: shadcn.PopoverConfiguration(
                       anchor: shadcn.LinkedAnchor(state),
                       alignment: Alignment.topCenter,
                       offset: const Offset(0, 4),
                       widthConstraint:
                           shadcn.PopoverConstraint.anchorFixedSize,
                     ),
                   ),
                   value: state.value,
                   // 此版本 Select 的默认值会覆盖 SelectTheme.canUnselect。
                   // ignore: deprecated_member_use
                   canUnselect: canUnselect,
                   enabled: onChanged != null,
                   placeholder: Text(label),
                   itemBuilder: (_, value) =>
                       items.firstWhere((item) => item.value == value).child,
                   popup:
                       popupBuilder ??
                       shadcn.SelectPopup<T>(
                         items: shadcn.SelectItemList(
                           children: [
                             for (final item in items)
                               shadcn.SelectItemButton<T>(
                                 value: item.value,
                                 child: item.child,
                               ),
                           ],
                         ),
                       ).call,
                   onChanged: (value) {
                     state.didChange(value);
                     onChanged?.call(value);
                   },
                 ),
               ),
               if (state.hasError) ...[
                 const SizedBox(height: 6),
                 Text(
                   state.errorText!,
                   style: TextStyle(fontSize: 12, color: colors.destructive),
                 ),
               ],
             ],
           );
         },
       );
}
