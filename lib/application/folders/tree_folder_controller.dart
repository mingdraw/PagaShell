import 'dart:async';

import 'package:get/get.dart';

import '../../domain/entities/folder.dart';
import '../../domain/repositories/folder_repository.dart';

/// 主机与凭证共用文件夹界面状态，实际写入由各自树仓库负责。
class TreeFolderController extends GetxController {
  TreeFolderController({
    required this.folderRepository,
    required this._saveFolder,
    required this._removeFolder,
  });
  final FolderRepository folderRepository;
  final Future<Folder> Function(Folder) _saveFolder;
  final Future<void> Function(String) _removeFolder;
  final RxList<Folder> folders = <Folder>[].obs;
  final RxSet<String> expanded = <String>{}.obs;
  StreamSubscription<List<Folder>>? _subscription;

  @override
  void onInit() {
    super.onInit();
    _subscription = folderRepository.watchAll().listen(folders.assignAll);
  }

  @override
  void onClose() {
    _subscription?.cancel();
    super.onClose();
  }

  List<Folder> childrenOf(String? parentId) {
    final result = folders
        .where((folder) => folder.parentId == parentId)
        .toList();
    result.sort((a, b) {
      final order = a.sortOrder.compareTo(b.sortOrder);
      return order != 0 ? order : a.name.compareTo(b.name);
    });
    return result;
  }

  Folder? byId(String? id) {
    if (id == null) return null;
    for (final folder in folders) {
      if (folder.id == id) return folder;
    }
    return null;
  }

  String pathOf(String? id) {
    final names = <String>[];
    var current = byId(id);
    var guard = folders.length + 1;
    while (current != null && guard-- > 0) {
      names.insert(0, current.name);
      current = byId(current.parentId);
    }
    return names.join(' / ');
  }

  bool isExpanded(String id) => expanded.contains(id);
  void toggleExpanded(String id) {
    if (!expanded.remove(id)) expanded.add(id);
  }

  bool isNameTaken(String name, {String? parentId, String? excludeId}) =>
      folders.any(
        (folder) =>
            folder.id != excludeId &&
            folder.parentId == parentId &&
            folder.name == name.trim(),
      );
  Future<Folder> create({required String name, String? parentId}) async {
    final folder = await _saveFolder(
      Folder(
        id: 'fld-${DateTime.now().microsecondsSinceEpoch}',
        name: name.trim(),
        parentId: parentId,
      ),
    );
    if (parentId != null) expanded.add(parentId);
    return folder;
  }

  Future<void> rename(String id, String name) async {
    final folder = byId(id);
    if (folder != null) await _saveFolder(folder.copyWith(name: name.trim()));
  }

  Future<void> remove(String id) async {
    await _removeFolder(id);
    expanded.remove(id);
  }
}
