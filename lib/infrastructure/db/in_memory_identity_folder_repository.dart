import '../../domain/repositories/identity_folder_repository.dart';
import 'in_memory_folder_repository.dart';

class InMemoryIdentityFolderRepository extends InMemoryFolderRepository
    implements IdentityFolderRepository {}
