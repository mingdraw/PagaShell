import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../theme/app_theme.dart';
import 'app_icon.dart';

class AppRadioCardOption<T> {
  const AppRadioCardOption({
    required this.value,
    required this.child,
    this.icon,
  });

  final T value;
  final Widget child;
  final AppIcons? icon;
}

/// 等宽的 shadcn Radio Card 选项，与 Flutter 核心 Form 校验互通。
class AppRadioCardField<T> extends FormField<T> {
  AppRadioCardField({
    required String label,
    required List<AppRadioCardOption<T>> items,
    required ValueChanged<T>? onChanged,
    super.initialValue,
    super.validator,
    super.key,
  }) : assert(items.isNotEmpty),
       super(
         enabled: onChanged != null,
         builder: (state) => Column(
           crossAxisAlignment: CrossAxisAlignment.stretch,
           children: [
             Text(
               label,
               style: const TextStyle(
                 fontSize: AppTheme.inputFontSize,
                 fontWeight: FontWeight.w500,
               ),
             ),
             const SizedBox(height: 6),
             shadcn.RadioGroup<T>(
               value: state.value,
               enabled: onChanged != null,
               onChanged: onChanged == null
                   ? null
                   : (value) {
                       state.didChange(value);
                       onChanged(value);
                     },
               child: Row(
                 children: [
                   for (var i = 0; i < items.length; i++) ...[
                     if (i != 0) const SizedBox(width: 8),
                     Expanded(
                       child: Semantics(
                         checked: state.value == items[i].value,
                         inMutuallyExclusiveGroup: true,
                         enabled: onChanged != null,
                         child: shadcn.RadioCard<T>(
                           value: items[i].value,
                           enabled: onChanged != null,
                           theme: const shadcn.RadioCardTheme(
                             padding: AppTheme.typeRadioCardPadding,
                           ),
                           child: DefaultTextStyle.merge(
                             style: const TextStyle(
                               fontSize: AppTheme.inputFontSize,
                             ),
                             child: Center(
                               child: Row(
                                 mainAxisSize: MainAxisSize.min,
                                 children: [
                                   if (items[i].icon case final icon?) ...[
                                     AppIcon(icon, size: AppTheme.inputIconSize),
                                     const SizedBox(width: 6),
                                   ],
                                   items[i].child,
                                 ],
                               ),
                             ),
                           ),
                         ),
                       ),
                     ),
                   ],
                 ],
               ),
             ),
             if (state.hasError) ...[
               const SizedBox(height: 6),
               Text(
                 state.errorText!,
                 style: TextStyle(
                   fontSize: AppTheme.inputFontSize,
                   color: shadcn.Theme.of(state.context)
                       .colorScheme
                       .destructive,
                 ),
               ),
             ],
           ],
         ),
       );
}
