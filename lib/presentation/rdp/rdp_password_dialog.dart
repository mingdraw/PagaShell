import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/session.dart';
import '../components/app_dialog.dart';
import '../components/app_icon.dart';
import '../components/app_icon_button.dart';
import '../components/app_text_form_field.dart';
import '../localization/app_translations.dart';
import '../theme/app_theme.dart';

typedef DesktopPasswordDecision = ({String password, String? username});

class RdpPasswordDialog extends StatefulWidget {
  const RdpPasswordDialog({
    required this.request,
    required this.onDecision,
    super.key,
  });

  final RdpPasswordRequest request;
  final ValueChanged<DesktopPasswordDecision?> onDecision;

  @override
  State<RdpPasswordDialog> createState() => _RdpPasswordDialogState();
}

class _RdpPasswordDialogState extends State<RdpPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _username = TextEditingController(text: widget.request.username);
  final _password = TextEditingController();
  bool _obscure = true;
  bool _decided = false;

  bool get _editsUsername =>
      widget.request.host.isVnc &&
      (widget.request.requiresUsername || widget.request.username.isNotEmpty);

  void _decide(DesktopPasswordDecision? decision) {
    if (_decided) return;
    _decided = true;
    widget.onDecision(decision);
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    _decide((
      password: _password.text,
      username: _editsUsername ? _username.text.trim() : null,
    ));
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final host = request.host;
    final colors = shadcn.Theme.of(context).colorScheme;
    final askingMacLogin =
        host.isVnc && request.requiresUsername && request.username.isEmpty;
    final title = host.isVnc
        ? (askingMacLogin
              ? 'macOS 远程桌面登录'
              : (_editsUsername ? 'VNC 登录凭据无效' : 'VNC 密码无效'))
        : 'RDP 登录凭据无效';
    final description = host.isVnc
        ? (askingMacLogin
              ? '请输入目标 Mac 的系统用户名和密码以连接屏幕共享。'
              : (_editsUsername
                    ? 'VNC 服务器未接受用户名或密码，请重新输入。'
                    : 'VNC 服务器未接受密码，请重新输入。'))
        : '用户名或密码未被 Windows 接受，请重新输入密码。';
    return AppDialog(
      maxWidth: 480,
      scrollable: true,
      title: Text(title.tr),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(description.tr),
            const SizedBox(height: 16),
            Text(
              '远程电脑：@host'.trParams({'host': '${host.hostname}:${host.port}'}),
            ),
            const SizedBox(height: 8),
            if (!host.isVnc)
              Text('用户名：@username'.trParams({'username': request.username})),
            if (!host.isVnc && request.domain.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('域：@domain'.trParams({'domain': request.domain})),
            ],
            if (request.error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                AppTranslations.error(request.error),
                style: TextStyle(fontSize: 12, color: colors.mutedForeground),
              ),
            ],
            const SizedBox(height: 20),
            if (_editsUsername) ...[
              AppTextFormField(
                key: const ValueKey('desktop-retry-username'),
                controller: _username,
                autofocus: request.username.isEmpty,
                enableSuggestions: false,
                autocorrect: false,
                smartPunctuation: false,
                validator: (value) =>
                    request.requiresUsername &&
                        (value == null || value.trim().isEmpty)
                    ? '请输入用户名'.tr
                    : null,
                decoration: AppInputDecoration(labelText: '用户名'.tr),
              ),
              const SizedBox(height: 12),
            ],
            AppTextFormField(
              controller: _password,
              autofocus: !_editsUsername || request.username.isNotEmpty,
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
                  icon: AppIcon(
                    _obscure ? AppIcons.eyeOff : AppIcons.eye,
                    size: AppTheme.inputIconSize,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              (_editsUsername ? '新凭据仅用于当前会话。' : '新密码仅用于当前会话。').tr,
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
