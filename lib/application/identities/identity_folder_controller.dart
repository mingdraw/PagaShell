import '../../domain/repositories/identity_folder_repository.dart';
import '../../domain/repositories/identity_tree_repository.dart';
import '../folders/tree_folder_controller.dart';

class IdentityFolderController extends TreeFolderController {
  IdentityFolderController({
    required IdentityFolderRepository repository,
    required IdentityTreeRepository treeRepository,
  }) : super(
         folderRepository: repository,
         saveFolder: treeRepository.saveFolder,
         removeFolder: treeRepository.removeFolder,
       );
}
