import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as shadcn;

import '../../application/session/session.dart';
import '../../application/session/session_controller.dart';
import '../components/app_dialog.dart';
import '../components/app_text_form_field.dart';
import '../navigation/app_navigation.dart';
import '../theme/app_theme.dart';

class BatchCommandDialog extends StatefulWidget {
  const BatchCommandDialog({required this.controller, super.key});

  final SessionController controller;

  @override
  State<BatchCommandDialog> createState() => _BatchCommandDialogState();
}

class _BatchCommandDialogState extends State<BatchCommandDialog> {
  final _command = TextEditingController();
  final _selected = <String>{};
  String? _error;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _command.addListener(_onCommandChanged);
  }

  void _onCommandChanged() => setState(() => _error = null);

  @override
  void dispose() {
    _command.dispose();
    super.dispose();
  }

  void _submit() {
    if (_submitted || _command.text.trim().isEmpty || _selected.isEmpty) return;
    final result = widget.controller.sendCommandToSessions(
      _selected,
      _command.text,
    );
    if (result.sent == 0) {
      setState(() {
        _error = '未能发送命令，请检查所选终端的连接状态'.tr;
      });
      return;
    }
    _submitted = true;
    AppNavigation.closeDialog(result: result);
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final sessions = widget.controller.commandSessions;
    final ids = sessions.map((session) => session.id).toSet();
    final selectedCount = _selected.intersection(ids).length;
    final colors = shadcn.Theme.of(context).colorScheme;
    return AppDialog(
      title: Text('批量执行命令'.tr),
      maxWidth: AppTheme.batchCommandDialogMaxWidth,
      scrollable: true,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '选择 SSH 终端'.tr,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (sessions.isNotEmpty) ...[
                const SizedBox(width: 12),
                shadcn.Checkbox(
                  state: selectedCount == ids.length
                      ? shadcn.CheckboxState.checked
                      : selectedCount == 0
                      ? shadcn.CheckboxState.unchecked
                      : shadcn.CheckboxState.indeterminate,
                  onChanged: (_) => setState(() {
                    if (selectedCount == ids.length) {
                      _selected.clear();
                    } else {
                      _selected
                        ..clear()
                        ..addAll(ids);
                    }
                    _error = null;
                  }),
                  trailing: Text('全选'.tr, style: const TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 12),
                Text(
                  '已选择 @count 个终端'.trParams({'count': '$selectedCount'}),
                  style: TextStyle(fontSize: 12, color: colors.mutedForeground),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          if (sessions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                '当前没有已连接的 SSH 终端'.tr,
                style: TextStyle(fontSize: 13, color: colors.mutedForeground),
              ),
            )
          else
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: math.min(
                  AppTheme.batchCommandSessionListHeight,
                  MediaQuery.sizeOf(context).height * 0.35,
                ),
              ),
              child: ListView.separated(
                primary: false,
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: (sessions.length + 1) ~/ 2,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppTheme.batchCommandSessionItemGap),
                itemBuilder: (context, index) {
                  final first = index * 2;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _sessionRow(sessions[first])),
                      const SizedBox(
                        width: AppTheme.batchCommandSessionColumnGap,
                      ),
                      Expanded(
                        child: first + 1 < sessions.length
                            ? _sessionRow(sessions[first + 1])
                            : const SizedBox.shrink(),
                      ),
                    ],
                  );
                },
              ),
            ),
          const SizedBox(height: 16),
          AppTextFormField(
            key: const ValueKey('batch-command-input'),
            controller: _command,
            autofocus: true,
            enableSuggestions: false,
            autocorrect: false,
            smartPunctuation: false,
            minLines: 3,
            maxLines: 8,
            decoration: AppInputDecoration(
              labelText: '命令'.tr,
              hintText: '输入单行或多行命令'.tr,
              helperText: '在所选终端的当前会话中执行，结果在各页签中查看。'.tr,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '请先确保所选终端处于命令提示符。'.tr,
            style: TextStyle(fontSize: 12, color: colors.mutedForeground),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(fontSize: 12, color: colors.destructive),
            ),
          ],
        ],
      ),
      actions: [
        shadcn.OutlineButton(
          onPressed: () => AppNavigation.closeDialog<BatchCommandResult>(),
          child: Text('取消'.tr),
        ),
        shadcn.PrimaryButton(
          key: const ValueKey('batch-command-execute'),
          onPressed:
              !_submitted &&
                  selectedCount > 0 &&
                  _command.text.trim().isNotEmpty
              ? _submit
              : null,
          child: Text('执行命令'.tr),
        ),
      ],
    );
  });

  Widget _sessionRow(Session session) {
    final colors = shadcn.Theme.of(context).colorScheme;
    final selected = _selected.contains(session.id);
    final index = widget.controller.sessions.indexWhere(
      (item) => item.id == session.id,
    );
    return Container(
      constraints: const BoxConstraints(
        minHeight: AppTheme.batchCommandSessionItemHeight,
      ),
      padding: AppTheme.batchCommandSessionItemPadding,
      decoration: BoxDecoration(
        color: selected ? colors.accent : colors.background,
        border: Border.all(color: colors.border),
        borderRadius: BorderRadius.circular(AppTheme.commandPaletteItemRadius),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => shadcn.Checkbox(
          key: ValueKey('batch-target-${session.id}'),
          state: selected
              ? shadcn.CheckboxState.checked
              : shadcn.CheckboxState.unchecked,
          onChanged: (state) => setState(() {
            if (state == shadcn.CheckboxState.checked) {
              _selected.add(session.id);
            } else {
              _selected.remove(session.id);
            }
            _error = null;
          }),
          trailing: SizedBox(
            width: constraints.maxWidth - 24,
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, height: 1.3),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 5,
                  child: Text(
                    session.address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.3,
                      color: colors.mutedForeground,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '页签 @index'.trParams({'index': '${index + 1}'}),
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.3,
                    color: colors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
