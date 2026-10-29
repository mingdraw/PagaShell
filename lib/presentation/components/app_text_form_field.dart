import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../theme/app_theme.dart';

/// Flutter Form 校验与 shadcn 输入框的适配；控制器仍由表单宿主持有。
class AppTextFormField extends FormField<String> {
  AppTextFormField({
    required this.controller,
    AppInputDecoration decoration = const AppInputDecoration(),
    bool autofocus = false,
    FocusNode? focusNode,
    bool obscureText = false,
    bool enableSuggestions = true,
    bool autocorrect = true,
    bool smartPunctuation = true,
    int? maxLines = 1,
    int? minLines,
    ValueChanged<String>? onFieldSubmitted,
    super.enabled = true,
    super.autovalidateMode,
    FormFieldValidator<String>? validator,
    super.key,
  }) : super(
         initialValue: controller.text,
         validator: (_) => validator?.call(controller.text),
         builder: (state) {
           final colors = shadcn.Theme.of(state.context).colorScheme;
           final input = Column(
             crossAxisAlignment: CrossAxisAlignment.start,
             children: [
               Semantics(
                 label: decoration.labelText,
                 child: ConstrainedBox(
                   constraints: const BoxConstraints(
                     minHeight: AppTheme.inputMinHeight,
                   ),
                   child: shadcn.TextField(
                     controller: controller,
                     enabled: enabled,
                     autofocus: autofocus,
                     focusNode: focusNode,
                     obscureText: obscureText,
                     enableSuggestions: enableSuggestions,
                     autocorrect: autocorrect,
                     smartDashesType: smartPunctuation
                         ? SmartDashesType.enabled
                         : SmartDashesType.disabled,
                     smartQuotesType: smartPunctuation
                         ? SmartQuotesType.enabled
                         : SmartQuotesType.disabled,
                     keyboardType: maxLines == 1
                         ? null
                         : TextInputType.multiline,
                     textInputAction: maxLines == 1
                         ? null
                         : TextInputAction.newline,
                     maxLines: maxLines,
                     minLines: minLines,
                     hintText: decoration.hintText,
                     placeholder: decoration.hintText == null
                         ? null
                         : Text(
                             decoration.hintText!,
                             style: const TextStyle(
                               fontSize: AppTheme.inputFontSize,
                             ),
                           ),
                     style: const TextStyle(fontSize: AppTheme.inputFontSize),
                     onChanged: (value) {
                       // shadcn 0.0.55 retains an external controller listener
                       // after disposal when conditional form fields are removed.
                       if (state.mounted) state.didChange(value);
                     },
                     onSubmitted: onFieldSubmitted,
                     border: state.hasError
                         ? Border.all(color: colors.destructive)
                         : null,
                     features: [
                       if (decoration.header != null)
                         shadcn.InputFeature.above(decoration.header!),
                       if (decoration.suffixIcon != null)
                         shadcn.InputFeature.trailing(decoration.suffixIcon!),
                       if (decoration.footer != null)
                         shadcn.InputFeature.below(decoration.footer!),
                     ],
                   ),
                 ),
               ),
               if (state.errorText != null ||
                   decoration.helperText != null) ...[
                 const SizedBox(height: 6),
                 Text(
                   state.errorText ?? decoration.helperText!,
                   style: TextStyle(
                     fontSize: 12,
                     color: state.hasError
                         ? colors.destructive
                         : colors.mutedForeground,
                   ),
                 ),
               ],
             ],
           );
           if (decoration.labelText == null) return input;
           final labelText = Text(
             decoration.labelText!,
             style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
           );
           final label = decoration.labelTrailing == null
               ? labelText
               : Row(
                   children: [
                     Expanded(child: labelText),
                     decoration.labelTrailing!,
                   ],
                 );
           if (decoration.inlineLabel) {
             return Row(
               crossAxisAlignment: CrossAxisAlignment.start,
               children: [
                 Padding(padding: const EdgeInsets.only(top: 8), child: label),
                 const SizedBox(width: 12),
                 Expanded(child: input),
               ],
             );
           }
           return Column(
             crossAxisAlignment: CrossAxisAlignment.start,
             children: [label, const SizedBox(height: 6), input],
           );
         },
       );

  final TextEditingController controller;
}

/// 表单文案、标签操作与尾部操作的配置，不依赖 Material InputDecoration。
class AppInputDecoration {
  const AppInputDecoration({
    this.labelText,
    this.labelTrailing,
    this.inlineLabel = false,
    this.hintText,
    this.helperText,
    this.suffixIcon,
    this.header,
    this.footer,
  });
  final String? labelText;
  final Widget? labelTrailing;
  final bool inlineLabel;
  final String? hintText;
  final String? helperText;
  final Widget? suffixIcon;
  final Widget? header;
  final Widget? footer;
}
