import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/folders/folder_controller.dart';
import '../../application/folders/tree_folder_controller.dart';
import '../components/app_dialog.dart';
import '../components/app_text_form_field.dart';
import '../navigation/app_navigation.dart';
import '../theme/app_theme.dart';

/// 新建 / 重命名文件夹对话框。
///
/// [folderId] 非空表示重命名该文件夹；为空表示在 [parentId] 下新建。
Future<void> showFolderDialog(
  BuildContext context, {
  String? folderId,
  String? parentId,
  TreeFolderController? folderController,
}) async {
  final controller = folderController ?? Get.find<FolderController>();
  final isRename = folderId != null;
  final initial = isRename ? controller.byId(folderId)?.name ?? '' : '';
  // 同级唯一性校验范围：重命名时是自身所在父级，新建时是目标父级。
  final scopeParentId = isRename
      ? controller.byId(folderId)?.parentId
      : parentId;

  final name = await AppNavigation.dialog<String>(
    _FolderNameDialog(
      title: isRename ? '重命名文件夹' : '新建文件夹',
      initial: initial,
      validator: (name) {
        if (name.isEmpty) return '必填'.tr;
        final taken = controller.isNameTaken(
          name,
          parentId: scopeParentId,
          excludeId: folderId,
        );
        return taken ? '同级下已存在同名文件夹'.tr : null;
      },
    ),
  );

  if (name == null || name.isEmpty) return;
  if (isRename) {
    await controller.rename(folderId, name);
  } else {
    await controller.create(name: name, parentId: parentId);
  }
}

/// 文件夹命名对话框。作为 StatefulWidget 自持有 [TextEditingController]，
/// 在自身 dispose 时释放——生命周期与退出动画一致，避免动画期间访问已释放的
/// controller（触发 `_dependents.isEmpty` / `attached` 断言崩溃）。
class _FolderNameDialog extends StatefulWidget {
  const _FolderNameDialog({
    required this.title,
    required this.initial,
    required this.validator,
  });

  final String title;
  final String initial;

  /// 返回错误文案；null 表示通过。入参已去首尾空白。
  final String? Function(String name) validator;

  @override
  State<_FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<_FolderNameDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _textController = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    AppNavigation.closeDialog(result: _textController.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: Text(widget.title.tr),
      maxWidth: AppTheme.folderDialogMaxWidth,
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppTextFormField(
              controller: _textController,
              autofocus: true,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              decoration: AppInputDecoration(labelText: '名称'.tr),
              validator: (v) => widget.validator((v ?? '').trim()),
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        shadcn.OutlineButton(
          onPressed: () => AppNavigation.closeDialog<void>(),
          child: Text('取消'.tr),
        ),
        shadcn.PrimaryButton(onPressed: _submit, child: Text('确定'.tr)),
      ],
    );
  }
}

/// 确认删除文件夹（其内容上移到父级）。
Future<void> confirmDeleteFolder(
  BuildContext context,
  String folderId, {
  TreeFolderController? folderController,
  bool containsIdentities = false,
  bool containsGateways = false,
}) async {
  final controller = folderController ?? Get.find<FolderController>();
  final folder = controller.byId(folderId);
  if (folder == null) return;

  final ok = await AppNavigation.dialog<bool>(
    AppDialog(
      title: Text('删除文件夹「@name」？'.trParams({'name': folder.name})),
      content: Text(
        (containsIdentities
                ? '其中的子文件夹与凭证会移动到上一级，不会被删除。'
                : containsGateways
                ? '其中的子文件夹与网关会移动到上一级，不会被删除。'
                : '其中的子文件夹与服务会移动到上一级，不会被删除。')
            .tr,
      ),
      actions: [
        shadcn.OutlineButton(
          onPressed: () => AppNavigation.closeDialog(result: false),
          child: Text('取消'.tr),
        ),
        shadcn.PrimaryButton(
          onPressed: () => AppNavigation.closeDialog(result: true),
          child: Text('删除'.tr),
        ),
      ],
    ),
  );
  if (ok ?? false) await controller.remove(folderId);
}
