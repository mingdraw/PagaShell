import '../../domain/repositories/host_repository.dart';
import '../../domain/repositories/host_tree_repository.dart';
import 'tree_folder_controller.dart';

/// 主机文件夹控制器，删除时将直接子项移到父级。
class FolderController extends TreeFolderController {
  FolderController({
    required super.folderRepository,
    required this.hostRepository,
    required this.treeRepository,
  }) : super(
         saveFolder: treeRepository.saveFolder,
         removeFolder: treeRepository.removeFolder,
       );
  final HostRepository hostRepository;
  final HostTreeRepository treeRepository;
}
