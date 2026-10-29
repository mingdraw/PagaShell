import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/session.dart';
import '../components/app_dialog.dart';
import '../components/app_icon_button.dart';
import '../components/app_text_form_field.dart';
import '../theme/app_theme.dart';

class RdpPasswordDialog extends StatefulWidget {
  const RdpPasswordDialog({
    required this.request,
    required this.onDecision,
    super.key,
  });

  final RdpPasswordRequest request;
  final ValueChanged<String?> onDecision;

  @override
  State<RdpPasswordDialog> createState() => _RdpPasswordDialogState();
}

class _RdpPasswordDialogState extends State<RdpPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _decided = false;

  void _decide(String? password) {
    if (_decided) return;
    _decided = true;
    widget.onDecision(password);
  }

  void _submit() {
    if (_formKey.currentState!.validate()) _decide(_password.text);
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final host = request.host;
    final colors = shadcn.Theme.of(context).colorScheme;
    return AppDialog(
      maxWidth: 480,
      scrollable: true,
      title: Text((host.isVnc ? 'VNC 密码无效' : 'RDP 登录凭据无效').tr),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              (host.isVnc
                      ? 'VNC 服务器未接受密码，请重新输入。'
                      : '用户名或密码未被 Windows 接受，请重新输入密码。')
                  .tr,
            ),
            const SizedBox(height: 16),
            Text(
              '远程电脑：@host'.trParams({'host': '${host.hostname}:${host.port}'}),
            ),
            const SizedBox(height: 8),
            if (!host.isVnc)
              Text('用户名：@username'.trParams({'username': request.username})),
            if (host.rdpDomain.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('域：@domain'.trParams({'domain': host.rdpDomain})),
            ],
            const SizedBox(height: 20),
            AppTextFormField(
              controller: _password,
              autofocus: true,
              obscureText: _obscure,
              enableSuggestions: false,
              autocorrect: false,
              smartPunctuation: false,
              validator: (value) =>
                  value == null || value.isEmpty ? '请输入密码'.tr : null,
              onFieldSubmitted: (_) => _submit(),
              decoration: AppInputDecoration(
                labelText: '密码'.tr,
                suffixIcon: AppIconButton(
                  semanticLabel: (_obscure ? '显示密码' : '隐藏密码').tr,
                  density: shadcn.ButtonDensity.compact,
                  icon: Icon(
                    _obscure
                        ? shadcn.LucideIcons.eyeOff
                        : shadcn.LucideIcons.eye,
                    size: AppTheme.inputIconSize,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '新密码仅用于当前会话。'.tr,
              style: TextStyle(fontSize: 12, color: colors.mutedForeground),
            ),
          ],
        ),
      ),
      actions: [
        shadcn.OutlineButton(
          onPressed: () => _decide(null),
          child: Text('取消'.tr),
        ),
        shadcn.PrimaryButton(onPressed: _submit, child: Text('继续连接'.tr)),
      ],
    );
  }
}
