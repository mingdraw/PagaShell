// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $FoldersTable extends Folders with TableInfo<$FoldersTable, FolderRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FoldersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _isGatewayMeta = const VerificationMeta(
    'isGateway',
  );
  @override
  late final GeneratedColumn<bool> isGateway = GeneratedColumn<bool>(
    'is_gateway',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_gateway" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<String> parentId = GeneratedColumn<String>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    isGateway,
    id,
    name,
    parentId,
    sortOrder,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'folders';
  @override
  VerificationContext validateIntegrity(
    Insertable<FolderRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('is_gateway')) {
      context.handle(
        _isGatewayMeta,
        isGateway.isAcceptableOrUnknown(data['is_gateway']!, _isGatewayMeta),
      );
    }
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  FolderRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FolderRow(
      isGateway: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_gateway'],
      )!,
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_id'],
      ),
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
    );
  }

  @override
  $FoldersTable createAlias(String alias) {
    return $FoldersTable(attachedDatabase, alias);
  }
}

class FolderRow extends DataClass implements Insertable<FolderRow> {
  final bool isGateway;
  final String id;
  final String name;
  final String? parentId;
  final int sortOrder;
  const FolderRow({
    required this.isGateway,
    required this.id,
    required this.name,
    this.parentId,
    required this.sortOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['is_gateway'] = Variable<bool>(isGateway);
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<String>(parentId);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  FoldersCompanion toCompanion(bool nullToAbsent) {
    return FoldersCompanion(
      isGateway: Value(isGateway),
      id: Value(id),
      name: Value(name),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      sortOrder: Value(sortOrder),
    );
  }

  factory FolderRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FolderRow(
      isGateway: serializer.fromJson<bool>(json['isGateway']),
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      parentId: serializer.fromJson<String?>(json['parentId']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'isGateway': serializer.toJson<bool>(isGateway),
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'parentId': serializer.toJson<String?>(parentId),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  FolderRow copyWith({
    bool? isGateway,
    String? id,
    String? name,
    Value<String?> parentId = const Value.absent(),
    int? sortOrder,
  }) => FolderRow(
    isGateway: isGateway ?? this.isGateway,
    id: id ?? this.id,
    name: name ?? this.name,
    parentId: parentId.present ? parentId.value : this.parentId,
    sortOrder: sortOrder ?? this.sortOrder,
  );
  FolderRow copyWithCompanion(FoldersCompanion data) {
    return FolderRow(
      isGateway: data.isGateway.present ? data.isGateway.value : this.isGateway,
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FolderRow(')
          ..write('isGateway: $isGateway, ')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('parentId: $parentId, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(isGateway, id, name, parentId, sortOrder);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FolderRow &&
          other.isGateway == this.isGateway &&
          other.id == this.id &&
          other.name == this.name &&
          other.parentId == this.parentId &&
          other.sortOrder == this.sortOrder);
}

class FoldersCompanion extends UpdateCompanion<FolderRow> {
  final Value<bool> isGateway;
  final Value<String> id;
  final Value<String> name;
  final Value<String?> parentId;
  final Value<int> sortOrder;
  final Value<int> rowid;
  const FoldersCompanion({
    this.isGateway = const Value.absent(),
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.parentId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FoldersCompanion.insert({
    this.isGateway = const Value.absent(),
    required String id,
    required String name,
    this.parentId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name);
  static Insertable<FolderRow> custom({
    Expression<bool>? isGateway,
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? parentId,
    Expression<int>? sortOrder,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (isGateway != null) 'is_gateway': isGateway,
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (parentId != null) 'parent_id': parentId,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FoldersCompanion copyWith({
    Value<bool>? isGateway,
    Value<String>? id,
    Value<String>? name,
    Value<String?>? parentId,
    Value<int>? sortOrder,
    Value<int>? rowid,
  }) {
    return FoldersCompanion(
      isGateway: isGateway ?? this.isGateway,
      id: id ?? this.id,
      name: name ?? this.name,
      parentId: parentId ?? this.parentId,
      sortOrder: sortOrder ?? this.sortOrder,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (isGateway.present) {
      map['is_gateway'] = Variable<bool>(isGateway.value);
    }
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<String>(parentId.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FoldersCompanion(')
          ..write('isGateway: $isGateway, ')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('parentId: $parentId, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $IdentityFoldersTable extends IdentityFolders
    with TableInfo<$IdentityFoldersTable, IdentityFolderRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $IdentityFoldersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<String> parentId = GeneratedColumn<String>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [id, name, parentId, sortOrder];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'identity_folders';
  @override
  VerificationContext validateIntegrity(
    Insertable<IdentityFolderRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  IdentityFolderRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return IdentityFolderRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_id'],
      ),
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
    );
  }

  @override
  $IdentityFoldersTable createAlias(String alias) {
    return $IdentityFoldersTable(attachedDatabase, alias);
  }
}

class IdentityFolderRow extends DataClass
    implements Insertable<IdentityFolderRow> {
  final String id;
  final String name;
  final String? parentId;
  final int sortOrder;
  const IdentityFolderRow({
    required this.id,
    required this.name,
    this.parentId,
    required this.sortOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<String>(parentId);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  IdentityFoldersCompanion toCompanion(bool nullToAbsent) {
    return IdentityFoldersCompanion(
      id: Value(id),
      name: Value(name),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      sortOrder: Value(sortOrder),
    );
  }

  factory IdentityFolderRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return IdentityFolderRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      parentId: serializer.fromJson<String?>(json['parentId']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'parentId': serializer.toJson<String?>(parentId),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  IdentityFolderRow copyWith({
    String? id,
    String? name,
    Value<String?> parentId = const Value.absent(),
    int? sortOrder,
  }) => IdentityFolderRow(
    id: id ?? this.id,
    name: name ?? this.name,
    parentId: parentId.present ? parentId.value : this.parentId,
    sortOrder: sortOrder ?? this.sortOrder,
  );
  IdentityFolderRow copyWithCompanion(IdentityFoldersCompanion data) {
    return IdentityFolderRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('IdentityFolderRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('parentId: $parentId, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, parentId, sortOrder);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is IdentityFolderRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.parentId == this.parentId &&
          other.sortOrder == this.sortOrder);
}

class IdentityFoldersCompanion extends UpdateCompanion<IdentityFolderRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<String?> parentId;
  final Value<int> sortOrder;
  final Value<int> rowid;
  const IdentityFoldersCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.parentId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  IdentityFoldersCompanion.insert({
    required String id,
    required String name,
    this.parentId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name);
  static Insertable<IdentityFolderRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? parentId,
    Expression<int>? sortOrder,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (parentId != null) 'parent_id': parentId,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (rowid != null) 'rowid': rowid,
    });
  }

  IdentityFoldersCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String?>? parentId,
    Value<int>? sortOrder,
    Value<int>? rowid,
  }) {
    return IdentityFoldersCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      parentId: parentId ?? this.parentId,
      sortOrder: sortOrder ?? this.sortOrder,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<String>(parentId.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('IdentityFoldersCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('parentId: $parentId, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $HostsTable extends Hosts with TableInfo<$HostsTable, HostRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HostsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _isGatewayMeta = const VerificationMeta(
    'isGateway',
  );
  @override
  late final GeneratedColumn<bool> isGateway = GeneratedColumn<bool>(
    'is_gateway',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_gateway" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _gatewayIdMeta = const VerificationMeta(
    'gatewayId',
  );
  @override
  late final GeneratedColumn<String> gatewayId = GeneratedColumn<String>(
    'gateway_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _gatewayTypeMeta = const VerificationMeta(
    'gatewayType',
  );
  @override
  late final GeneratedColumn<String> gatewayType = GeneratedColumn<String>(
    'gateway_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('ssh'),
  );
  static const VerificationMeta _rdpDomainMeta = const VerificationMeta(
    'rdpDomain',
  );
  @override
  late final GeneratedColumn<String> rdpDomain = GeneratedColumn<String>(
    'rdp_domain',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _pageClientIdMeta = const VerificationMeta(
    'pageClientId',
  );
  @override
  late final GeneratedColumn<String> pageClientId = GeneratedColumn<String>(
    'page_client_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _pageServerFingerprintMeta =
      const VerificationMeta('pageServerFingerprint');
  @override
  late final GeneratedColumn<String> pageServerFingerprint =
      GeneratedColumn<String>(
        'page_server_fingerprint',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant(''),
      );
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hostnameMeta = const VerificationMeta(
    'hostname',
  );
  @override
  late final GeneratedColumn<String> hostname = GeneratedColumn<String>(
    'hostname',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
    'port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(22),
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('root'),
  );
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
    'note',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _tagsMeta = const VerificationMeta('tags');
  @override
  late final GeneratedColumn<String> tags = GeneratedColumn<String>(
    'tags',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _folderIdMeta = const VerificationMeta(
    'folderId',
  );
  @override
  late final GeneratedColumn<String> folderId = GeneratedColumn<String>(
    'folder_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _identityIdMeta = const VerificationMeta(
    'identityId',
  );
  @override
  late final GeneratedColumn<String> identityId = GeneratedColumn<String>(
    'identity_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _colorValueMeta = const VerificationMeta(
    'colorValue',
  );
  @override
  late final GeneratedColumn<int> colorValue = GeneratedColumn<int>(
    'color_value',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _forwardPortsJsonMeta = const VerificationMeta(
    'forwardPortsJson',
  );
  @override
  late final GeneratedColumn<String> forwardPortsJson = GeneratedColumn<String>(
    'forward_ports_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _proxyConfigJsonMeta = const VerificationMeta(
    'proxyConfigJson',
  );
  @override
  late final GeneratedColumn<String> proxyConfigJson = GeneratedColumn<String>(
    'proxy_config_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  @override
  List<GeneratedColumn> get $columns => [
    isGateway,
    gatewayId,
    gatewayType,
    rdpDomain,
    pageClientId,
    pageServerFingerprint,
    id,
    name,
    hostname,
    port,
    username,
    note,
    tags,
    folderId,
    identityId,
    colorValue,
    sortOrder,
    forwardPortsJson,
    proxyConfigJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'hosts';
  @override
  VerificationContext validateIntegrity(
    Insertable<HostRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('is_gateway')) {
      context.handle(
        _isGatewayMeta,
        isGateway.isAcceptableOrUnknown(data['is_gateway']!, _isGatewayMeta),
      );
    }
    if (data.containsKey('gateway_id')) {
      context.handle(
        _gatewayIdMeta,
        gatewayId.isAcceptableOrUnknown(data['gateway_id']!, _gatewayIdMeta),
      );
    }
    if (data.containsKey('gateway_type')) {
      context.handle(
        _gatewayTypeMeta,
        gatewayType.isAcceptableOrUnknown(
          data['gateway_type']!,
          _gatewayTypeMeta,
        ),
      );
    }
    if (data.containsKey('rdp_domain')) {
      context.handle(
        _rdpDomainMeta,
        rdpDomain.isAcceptableOrUnknown(data['rdp_domain']!, _rdpDomainMeta),
      );
    }
    if (data.containsKey('page_client_id')) {
      context.handle(
        _pageClientIdMeta,
        pageClientId.isAcceptableOrUnknown(
          data['page_client_id']!,
          _pageClientIdMeta,
        ),
      );
    }
    if (data.containsKey('page_server_fingerprint')) {
      context.handle(
        _pageServerFingerprintMeta,
        pageServerFingerprint.isAcceptableOrUnknown(
          data['page_server_fingerprint']!,
          _pageServerFingerprintMeta,
        ),
      );
    }
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('hostname')) {
      context.handle(
        _hostnameMeta,
        hostname.isAcceptableOrUnknown(data['hostname']!, _hostnameMeta),
      );
    } else if (isInserting) {
      context.missing(_hostnameMeta);
    }
    if (data.containsKey('port')) {
      context.handle(
        _portMeta,
        port.isAcceptableOrUnknown(data['port']!, _portMeta),
      );
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    }
    if (data.containsKey('note')) {
      context.handle(
        _noteMeta,
        note.isAcceptableOrUnknown(data['note']!, _noteMeta),
      );
    }
    if (data.containsKey('tags')) {
      context.handle(
        _tagsMeta,
        tags.isAcceptableOrUnknown(data['tags']!, _tagsMeta),
      );
    }
    if (data.containsKey('folder_id')) {
      context.handle(
        _folderIdMeta,
        folderId.isAcceptableOrUnknown(data['folder_id']!, _folderIdMeta),
      );
    }
    if (data.containsKey('identity_id')) {
      context.handle(
        _identityIdMeta,
        identityId.isAcceptableOrUnknown(data['identity_id']!, _identityIdMeta),
      );
    }
    if (data.containsKey('color_value')) {
      context.handle(
        _colorValueMeta,
        colorValue.isAcceptableOrUnknown(data['color_value']!, _colorValueMeta),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    if (data.containsKey('forward_ports_json')) {
      context.handle(
        _forwardPortsJsonMeta,
        forwardPortsJson.isAcceptableOrUnknown(
          data['forward_ports_json']!,
          _forwardPortsJsonMeta,
        ),
      );
    }
    if (data.containsKey('proxy_config_json')) {
      context.handle(
        _proxyConfigJsonMeta,
        proxyConfigJson.isAcceptableOrUnknown(
          data['proxy_config_json']!,
          _proxyConfigJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  HostRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HostRow(
      isGateway: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_gateway'],
      )!,
      gatewayId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}gateway_id'],
      ),
      gatewayType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}gateway_type'],
      )!,
      rdpDomain: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}rdp_domain'],
      )!,
      pageClientId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}page_client_id'],
      )!,
      pageServerFingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}page_server_fingerprint'],
      )!,
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      hostname: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}hostname'],
      )!,
      port: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}port'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      note: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note'],
      )!,
      tags: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags'],
      )!,
      folderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}folder_id'],
      ),
      identityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}identity_id'],
      ),
      colorValue: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}color_value'],
      ),
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      forwardPortsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}forward_ports_json'],
      )!,
      proxyConfigJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}proxy_config_json'],
      )!,
    );
  }

  @override
  $HostsTable createAlias(String alias) {
    return $HostsTable(attachedDatabase, alias);
  }
}

class HostRow extends DataClass implements Insertable<HostRow> {
  final bool isGateway;
  final String? gatewayId;
  final String gatewayType;
  final String rdpDomain;
  final String pageClientId;
  final String pageServerFingerprint;
  final String id;
  final String name;
  final String hostname;
  final int port;
  final String username;
  final String note;
  final String tags;
  final String? folderId;
  final String? identityId;
  final int? colorValue;
  final int sortOrder;
  final String forwardPortsJson;
  final String proxyConfigJson;
  const HostRow({
    required this.isGateway,
    this.gatewayId,
    required this.gatewayType,
    required this.rdpDomain,
    required this.pageClientId,
    required this.pageServerFingerprint,
    required this.id,
    required this.name,
    required this.hostname,
    required this.port,
    required this.username,
    required this.note,
    required this.tags,
    this.folderId,
    this.identityId,
    this.colorValue,
    required this.sortOrder,
    required this.forwardPortsJson,
    required this.proxyConfigJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['is_gateway'] = Variable<bool>(isGateway);
    if (!nullToAbsent || gatewayId != null) {
      map['gateway_id'] = Variable<String>(gatewayId);
    }
    map['gateway_type'] = Variable<String>(gatewayType);
    map['rdp_domain'] = Variable<String>(rdpDomain);
    map['page_client_id'] = Variable<String>(pageClientId);
    map['page_server_fingerprint'] = Variable<String>(pageServerFingerprint);
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['hostname'] = Variable<String>(hostname);
    map['port'] = Variable<int>(port);
    map['username'] = Variable<String>(username);
    map['note'] = Variable<String>(note);
    map['tags'] = Variable<String>(tags);
    if (!nullToAbsent || folderId != null) {
      map['folder_id'] = Variable<String>(folderId);
    }
    if (!nullToAbsent || identityId != null) {
      map['identity_id'] = Variable<String>(identityId);
    }
    if (!nullToAbsent || colorValue != null) {
      map['color_value'] = Variable<int>(colorValue);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    map['forward_ports_json'] = Variable<String>(forwardPortsJson);
    map['proxy_config_json'] = Variable<String>(proxyConfigJson);
    return map;
  }

  HostsCompanion toCompanion(bool nullToAbsent) {
    return HostsCompanion(
      isGateway: Value(isGateway),
      gatewayId: gatewayId == null && nullToAbsent
          ? const Value.absent()
          : Value(gatewayId),
      gatewayType: Value(gatewayType),
      rdpDomain: Value(rdpDomain),
      pageClientId: Value(pageClientId),
      pageServerFingerprint: Value(pageServerFingerprint),
      id: Value(id),
      name: Value(name),
      hostname: Value(hostname),
      port: Value(port),
      username: Value(username),
      note: Value(note),
      tags: Value(tags),
      folderId: folderId == null && nullToAbsent
          ? const Value.absent()
          : Value(folderId),
      identityId: identityId == null && nullToAbsent
          ? const Value.absent()
          : Value(identityId),
      colorValue: colorValue == null && nullToAbsent
          ? const Value.absent()
          : Value(colorValue),
      sortOrder: Value(sortOrder),
      forwardPortsJson: Value(forwardPortsJson),
      proxyConfigJson: Value(proxyConfigJson),
    );
  }

  factory HostRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HostRow(
      isGateway: serializer.fromJson<bool>(json['isGateway']),
      gatewayId: serializer.fromJson<String?>(json['gatewayId']),
      gatewayType: serializer.fromJson<String>(json['gatewayType']),
      rdpDomain: serializer.fromJson<String>(json['rdpDomain']),
      pageClientId: serializer.fromJson<String>(json['pageClientId']),
      pageServerFingerprint: serializer.fromJson<String>(
        json['pageServerFingerprint'],
      ),
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      hostname: serializer.fromJson<String>(json['hostname']),
      port: serializer.fromJson<int>(json['port']),
      username: serializer.fromJson<String>(json['username']),
      note: serializer.fromJson<String>(json['note']),
      tags: serializer.fromJson<String>(json['tags']),
      folderId: serializer.fromJson<String?>(json['folderId']),
      identityId: serializer.fromJson<String?>(json['identityId']),
      colorValue: serializer.fromJson<int?>(json['colorValue']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      forwardPortsJson: serializer.fromJson<String>(json['forwardPortsJson']),
      proxyConfigJson: serializer.fromJson<String>(json['proxyConfigJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'isGateway': serializer.toJson<bool>(isGateway),
      'gatewayId': serializer.toJson<String?>(gatewayId),
      'gatewayType': serializer.toJson<String>(gatewayType),
      'rdpDomain': serializer.toJson<String>(rdpDomain),
      'pageClientId': serializer.toJson<String>(pageClientId),
      'pageServerFingerprint': serializer.toJson<String>(pageServerFingerprint),
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'hostname': serializer.toJson<String>(hostname),
      'port': serializer.toJson<int>(port),
      'username': serializer.toJson<String>(username),
      'note': serializer.toJson<String>(note),
      'tags': serializer.toJson<String>(tags),
      'folderId': serializer.toJson<String?>(folderId),
      'identityId': serializer.toJson<String?>(identityId),
      'colorValue': serializer.toJson<int?>(colorValue),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'forwardPortsJson': serializer.toJson<String>(forwardPortsJson),
      'proxyConfigJson': serializer.toJson<String>(proxyConfigJson),
    };
  }

  HostRow copyWith({
    bool? isGateway,
    Value<String?> gatewayId = const Value.absent(),
    String? gatewayType,
    String? rdpDomain,
    String? pageClientId,
    String? pageServerFingerprint,
    String? id,
    String? name,
    String? hostname,
    int? port,
    String? username,
    String? note,
    String? tags,
    Value<String?> folderId = const Value.absent(),
    Value<String?> identityId = const Value.absent(),
    Value<int?> colorValue = const Value.absent(),
    int? sortOrder,
    String? forwardPortsJson,
    String? proxyConfigJson,
  }) => HostRow(
    isGateway: isGateway ?? this.isGateway,
    gatewayId: gatewayId.present ? gatewayId.value : this.gatewayId,
    gatewayType: gatewayType ?? this.gatewayType,
    rdpDomain: rdpDomain ?? this.rdpDomain,
    pageClientId: pageClientId ?? this.pageClientId,
    pageServerFingerprint: pageServerFingerprint ?? this.pageServerFingerprint,
    id: id ?? this.id,
    name: name ?? this.name,
    hostname: hostname ?? this.hostname,
    port: port ?? this.port,
    username: username ?? this.username,
    note: note ?? this.note,
    tags: tags ?? this.tags,
    folderId: folderId.present ? folderId.value : this.folderId,
    identityId: identityId.present ? identityId.value : this.identityId,
    colorValue: colorValue.present ? colorValue.value : this.colorValue,
    sortOrder: sortOrder ?? this.sortOrder,
    forwardPortsJson: forwardPortsJson ?? this.forwardPortsJson,
    proxyConfigJson: proxyConfigJson ?? this.proxyConfigJson,
  );
  HostRow copyWithCompanion(HostsCompanion data) {
    return HostRow(
      isGateway: data.isGateway.present ? data.isGateway.value : this.isGateway,
      gatewayId: data.gatewayId.present ? data.gatewayId.value : this.gatewayId,
      gatewayType: data.gatewayType.present
          ? data.gatewayType.value
          : this.gatewayType,
      rdpDomain: data.rdpDomain.present ? data.rdpDomain.value : this.rdpDomain,
      pageClientId: data.pageClientId.present
          ? data.pageClientId.value
          : this.pageClientId,
      pageServerFingerprint: data.pageServerFingerprint.present
          ? data.pageServerFingerprint.value
          : this.pageServerFingerprint,
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      hostname: data.hostname.present ? data.hostname.value : this.hostname,
      port: data.port.present ? data.port.value : this.port,
      username: data.username.present ? data.username.value : this.username,
      note: data.note.present ? data.note.value : this.note,
      tags: data.tags.present ? data.tags.value : this.tags,
      folderId: data.folderId.present ? data.folderId.value : this.folderId,
      identityId: data.identityId.present
          ? data.identityId.value
          : this.identityId,
      colorValue: data.colorValue.present
          ? data.colorValue.value
          : this.colorValue,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      forwardPortsJson: data.forwardPortsJson.present
          ? data.forwardPortsJson.value
          : this.forwardPortsJson,
      proxyConfigJson: data.proxyConfigJson.present
          ? data.proxyConfigJson.value
          : this.proxyConfigJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HostRow(')
          ..write('isGateway: $isGateway, ')
          ..write('gatewayId: $gatewayId, ')
          ..write('gatewayType: $gatewayType, ')
          ..write('rdpDomain: $rdpDomain, ')
          ..write('pageClientId: $pageClientId, ')
          ..write('pageServerFingerprint: $pageServerFingerprint, ')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('hostname: $hostname, ')
          ..write('port: $port, ')
          ..write('username: $username, ')
          ..write('note: $note, ')
          ..write('tags: $tags, ')
          ..write('folderId: $folderId, ')
          ..write('identityId: $identityId, ')
          ..write('colorValue: $colorValue, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('forwardPortsJson: $forwardPortsJson, ')
          ..write('proxyConfigJson: $proxyConfigJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    isGateway,
    gatewayId,
    gatewayType,
    rdpDomain,
    pageClientId,
    pageServerFingerprint,
    id,
    name,
    hostname,
    port,
    username,
    note,
    tags,
    folderId,
    identityId,
    colorValue,
    sortOrder,
    forwardPortsJson,
    proxyConfigJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HostRow &&
          other.isGateway == this.isGateway &&
          other.gatewayId == this.gatewayId &&
          other.gatewayType == this.gatewayType &&
          other.rdpDomain == this.rdpDomain &&
          other.pageClientId == this.pageClientId &&
          other.pageServerFingerprint == this.pageServerFingerprint &&
          other.id == this.id &&
          other.name == this.name &&
          other.hostname == this.hostname &&
          other.port == this.port &&
          other.username == this.username &&
          other.note == this.note &&
          other.tags == this.tags &&
          other.folderId == this.folderId &&
          other.identityId == this.identityId &&
          other.colorValue == this.colorValue &&
          other.sortOrder == this.sortOrder &&
          other.forwardPortsJson == this.forwardPortsJson &&
          other.proxyConfigJson == this.proxyConfigJson);
}

class HostsCompanion extends UpdateCompanion<HostRow> {
  final Value<bool> isGateway;
  final Value<String?> gatewayId;
  final Value<String> gatewayType;
  final Value<String> rdpDomain;
  final Value<String> pageClientId;
  final Value<String> pageServerFingerprint;
  final Value<String> id;
  final Value<String> name;
  final Value<String> hostname;
  final Value<int> port;
  final Value<String> username;
  final Value<String> note;
  final Value<String> tags;
  final Value<String?> folderId;
  final Value<String?> identityId;
  final Value<int?> colorValue;
  final Value<int> sortOrder;
  final Value<String> forwardPortsJson;
  final Value<String> proxyConfigJson;
  final Value<int> rowid;
  const HostsCompanion({
    this.isGateway = const Value.absent(),
    this.gatewayId = const Value.absent(),
    this.gatewayType = const Value.absent(),
    this.rdpDomain = const Value.absent(),
    this.pageClientId = const Value.absent(),
    this.pageServerFingerprint = const Value.absent(),
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.hostname = const Value.absent(),
    this.port = const Value.absent(),
    this.username = const Value.absent(),
    this.note = const Value.absent(),
    this.tags = const Value.absent(),
    this.folderId = const Value.absent(),
    this.identityId = const Value.absent(),
    this.colorValue = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.forwardPortsJson = const Value.absent(),
    this.proxyConfigJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  HostsCompanion.insert({
    this.isGateway = const Value.absent(),
    this.gatewayId = const Value.absent(),
    this.gatewayType = const Value.absent(),
    this.rdpDomain = const Value.absent(),
    this.pageClientId = const Value.absent(),
    this.pageServerFingerprint = const Value.absent(),
    required String id,
    required String name,
    required String hostname,
    this.port = const Value.absent(),
    this.username = const Value.absent(),
    this.note = const Value.absent(),
    this.tags = const Value.absent(),
    this.folderId = const Value.absent(),
    this.identityId = const Value.absent(),
    this.colorValue = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.forwardPortsJson = const Value.absent(),
    this.proxyConfigJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       hostname = Value(hostname);
  static Insertable<HostRow> custom({
    Expression<bool>? isGateway,
    Expression<String>? gatewayId,
    Expression<String>? gatewayType,
    Expression<String>? rdpDomain,
    Expression<String>? pageClientId,
    Expression<String>? pageServerFingerprint,
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? hostname,
    Expression<int>? port,
    Expression<String>? username,
    Expression<String>? note,
    Expression<String>? tags,
    Expression<String>? folderId,
    Expression<String>? identityId,
    Expression<int>? colorValue,
    Expression<int>? sortOrder,
    Expression<String>? forwardPortsJson,
    Expression<String>? proxyConfigJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (isGateway != null) 'is_gateway': isGateway,
      if (gatewayId != null) 'gateway_id': gatewayId,
      if (gatewayType != null) 'gateway_type': gatewayType,
      if (rdpDomain != null) 'rdp_domain': rdpDomain,
      if (pageClientId != null) 'page_client_id': pageClientId,
      if (pageServerFingerprint != null)
        'page_server_fingerprint': pageServerFingerprint,
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (hostname != null) 'hostname': hostname,
      if (port != null) 'port': port,
      if (username != null) 'username': username,
      if (note != null) 'note': note,
      if (tags != null) 'tags': tags,
      if (folderId != null) 'folder_id': folderId,
      if (identityId != null) 'identity_id': identityId,
      if (colorValue != null) 'color_value': colorValue,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (forwardPortsJson != null) 'forward_ports_json': forwardPortsJson,
      if (proxyConfigJson != null) 'proxy_config_json': proxyConfigJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  HostsCompanion copyWith({
    Value<bool>? isGateway,
    Value<String?>? gatewayId,
    Value<String>? gatewayType,
    Value<String>? rdpDomain,
    Value<String>? pageClientId,
    Value<String>? pageServerFingerprint,
    Value<String>? id,
    Value<String>? name,
    Value<String>? hostname,
    Value<int>? port,
    Value<String>? username,
    Value<String>? note,
    Value<String>? tags,
    Value<String?>? folderId,
    Value<String?>? identityId,
    Value<int?>? colorValue,
    Value<int>? sortOrder,
    Value<String>? forwardPortsJson,
    Value<String>? proxyConfigJson,
    Value<int>? rowid,
  }) {
    return HostsCompanion(
      isGateway: isGateway ?? this.isGateway,
      gatewayId: gatewayId ?? this.gatewayId,
      gatewayType: gatewayType ?? this.gatewayType,
      rdpDomain: rdpDomain ?? this.rdpDomain,
      pageClientId: pageClientId ?? this.pageClientId,
      pageServerFingerprint:
          pageServerFingerprint ?? this.pageServerFingerprint,
      id: id ?? this.id,
      name: name ?? this.name,
      hostname: hostname ?? this.hostname,
      port: port ?? this.port,
      username: username ?? this.username,
      note: note ?? this.note,
      tags: tags ?? this.tags,
      folderId: folderId ?? this.folderId,
      identityId: identityId ?? this.identityId,
      colorValue: colorValue ?? this.colorValue,
      sortOrder: sortOrder ?? this.sortOrder,
      forwardPortsJson: forwardPortsJson ?? this.forwardPortsJson,
      proxyConfigJson: proxyConfigJson ?? this.proxyConfigJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (isGateway.present) {
      map['is_gateway'] = Variable<bool>(isGateway.value);
    }
    if (gatewayId.present) {
      map['gateway_id'] = Variable<String>(gatewayId.value);
    }
    if (gatewayType.present) {
      map['gateway_type'] = Variable<String>(gatewayType.value);
    }
    if (rdpDomain.present) {
      map['rdp_domain'] = Variable<String>(rdpDomain.value);
    }
    if (pageClientId.present) {
      map['page_client_id'] = Variable<String>(pageClientId.value);
    }
    if (pageServerFingerprint.present) {
      map['page_server_fingerprint'] = Variable<String>(
        pageServerFingerprint.value,
      );
    }
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (hostname.present) {
      map['hostname'] = Variable<String>(hostname.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (tags.present) {
      map['tags'] = Variable<String>(tags.value);
    }
    if (folderId.present) {
      map['folder_id'] = Variable<String>(folderId.value);
    }
    if (identityId.present) {
      map['identity_id'] = Variable<String>(identityId.value);
    }
    if (colorValue.present) {
      map['color_value'] = Variable<int>(colorValue.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (forwardPortsJson.present) {
      map['forward_ports_json'] = Variable<String>(forwardPortsJson.value);
    }
    if (proxyConfigJson.present) {
      map['proxy_config_json'] = Variable<String>(proxyConfigJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HostsCompanion(')
          ..write('isGateway: $isGateway, ')
          ..write('gatewayId: $gatewayId, ')
          ..write('gatewayType: $gatewayType, ')
          ..write('rdpDomain: $rdpDomain, ')
          ..write('pageClientId: $pageClientId, ')
          ..write('pageServerFingerprint: $pageServerFingerprint, ')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('hostname: $hostname, ')
          ..write('port: $port, ')
          ..write('username: $username, ')
          ..write('note: $note, ')
          ..write('tags: $tags, ')
          ..write('folderId: $folderId, ')
          ..write('identityId: $identityId, ')
          ..write('colorValue: $colorValue, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('forwardPortsJson: $forwardPortsJson, ')
          ..write('proxyConfigJson: $proxyConfigJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $IdentitiesTable extends Identities
    with TableInfo<$IdentitiesTable, IdentityRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $IdentitiesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _authTypeMeta = const VerificationMeta(
    'authType',
  );
  @override
  late final GeneratedColumn<int> authType = GeneratedColumn<int>(
    'auth_type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _serviceTypeMeta = const VerificationMeta(
    'serviceType',
  );
  @override
  late final GeneratedColumn<String> serviceType = GeneratedColumn<String>(
    'service_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('ssh'),
  );
  static const VerificationMeta _secretRefMeta = const VerificationMeta(
    'secretRef',
  );
  @override
  late final GeneratedColumn<String> secretRef = GeneratedColumn<String>(
    'secret_ref',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _folderIdMeta = const VerificationMeta(
    'folderId',
  );
  @override
  late final GeneratedColumn<String> folderId = GeneratedColumn<String>(
    'folder_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    username,
    authType,
    serviceType,
    secretRef,
    folderId,
    sortOrder,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'identities';
  @override
  VerificationContext validateIntegrity(
    Insertable<IdentityRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    } else if (isInserting) {
      context.missing(_usernameMeta);
    }
    if (data.containsKey('auth_type')) {
      context.handle(
        _authTypeMeta,
        authType.isAcceptableOrUnknown(data['auth_type']!, _authTypeMeta),
      );
    }
    if (data.containsKey('service_type')) {
      context.handle(
        _serviceTypeMeta,
        serviceType.isAcceptableOrUnknown(
          data['service_type']!,
          _serviceTypeMeta,
        ),
      );
    }
    if (data.containsKey('secret_ref')) {
      context.handle(
        _secretRefMeta,
        secretRef.isAcceptableOrUnknown(data['secret_ref']!, _secretRefMeta),
      );
    }
    if (data.containsKey('folder_id')) {
      context.handle(
        _folderIdMeta,
        folderId.isAcceptableOrUnknown(data['folder_id']!, _folderIdMeta),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  IdentityRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return IdentityRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      authType: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}auth_type'],
      )!,
      serviceType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}service_type'],
      )!,
      secretRef: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}secret_ref'],
      ),
      folderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}folder_id'],
      ),
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
    );
  }

  @override
  $IdentitiesTable createAlias(String alias) {
    return $IdentitiesTable(attachedDatabase, alias);
  }
}

class IdentityRow extends DataClass implements Insertable<IdentityRow> {
  final String id;
  final String name;
  final String username;
  final int authType;
  final String serviceType;
  final String? secretRef;
  final String? folderId;
  final int sortOrder;
  const IdentityRow({
    required this.id,
    required this.name,
    required this.username,
    required this.authType,
    required this.serviceType,
    this.secretRef,
    this.folderId,
    required this.sortOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['username'] = Variable<String>(username);
    map['auth_type'] = Variable<int>(authType);
    map['service_type'] = Variable<String>(serviceType);
    if (!nullToAbsent || secretRef != null) {
      map['secret_ref'] = Variable<String>(secretRef);
    }
    if (!nullToAbsent || folderId != null) {
      map['folder_id'] = Variable<String>(folderId);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  IdentitiesCompanion toCompanion(bool nullToAbsent) {
    return IdentitiesCompanion(
      id: Value(id),
      name: Value(name),
      username: Value(username),
      authType: Value(authType),
      serviceType: Value(serviceType),
      secretRef: secretRef == null && nullToAbsent
          ? const Value.absent()
          : Value(secretRef),
      folderId: folderId == null && nullToAbsent
          ? const Value.absent()
          : Value(folderId),
      sortOrder: Value(sortOrder),
    );
  }

  factory IdentityRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return IdentityRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      username: serializer.fromJson<String>(json['username']),
      authType: serializer.fromJson<int>(json['authType']),
      serviceType: serializer.fromJson<String>(json['serviceType']),
      secretRef: serializer.fromJson<String?>(json['secretRef']),
      folderId: serializer.fromJson<String?>(json['folderId']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'username': serializer.toJson<String>(username),
      'authType': serializer.toJson<int>(authType),
      'serviceType': serializer.toJson<String>(serviceType),
      'secretRef': serializer.toJson<String?>(secretRef),
      'folderId': serializer.toJson<String?>(folderId),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  IdentityRow copyWith({
    String? id,
    String? name,
    String? username,
    int? authType,
    String? serviceType,
    Value<String?> secretRef = const Value.absent(),
    Value<String?> folderId = const Value.absent(),
    int? sortOrder,
  }) => IdentityRow(
    id: id ?? this.id,
    name: name ?? this.name,
    username: username ?? this.username,
    authType: authType ?? this.authType,
    serviceType: serviceType ?? this.serviceType,
    secretRef: secretRef.present ? secretRef.value : this.secretRef,
    folderId: folderId.present ? folderId.value : this.folderId,
    sortOrder: sortOrder ?? this.sortOrder,
  );
  IdentityRow copyWithCompanion(IdentitiesCompanion data) {
    return IdentityRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      username: data.username.present ? data.username.value : this.username,
      authType: data.authType.present ? data.authType.value : this.authType,
      serviceType: data.serviceType.present
          ? data.serviceType.value
          : this.serviceType,
      secretRef: data.secretRef.present ? data.secretRef.value : this.secretRef,
      folderId: data.folderId.present ? data.folderId.value : this.folderId,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('IdentityRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('username: $username, ')
          ..write('authType: $authType, ')
          ..write('serviceType: $serviceType, ')
          ..write('secretRef: $secretRef, ')
          ..write('folderId: $folderId, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    username,
    authType,
    serviceType,
    secretRef,
    folderId,
    sortOrder,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is IdentityRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.username == this.username &&
          other.authType == this.authType &&
          other.serviceType == this.serviceType &&
          other.secretRef == this.secretRef &&
          other.folderId == this.folderId &&
          other.sortOrder == this.sortOrder);
}

class IdentitiesCompanion extends UpdateCompanion<IdentityRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> username;
  final Value<int> authType;
  final Value<String> serviceType;
  final Value<String?> secretRef;
  final Value<String?> folderId;
  final Value<int> sortOrder;
  final Value<int> rowid;
  const IdentitiesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.username = const Value.absent(),
    this.authType = const Value.absent(),
    this.serviceType = const Value.absent(),
    this.secretRef = const Value.absent(),
    this.folderId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  IdentitiesCompanion.insert({
    required String id,
    required String name,
    required String username,
    this.authType = const Value.absent(),
    this.serviceType = const Value.absent(),
    this.secretRef = const Value.absent(),
    this.folderId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       username = Value(username);
  static Insertable<IdentityRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? username,
    Expression<int>? authType,
    Expression<String>? serviceType,
    Expression<String>? secretRef,
    Expression<String>? folderId,
    Expression<int>? sortOrder,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (username != null) 'username': username,
      if (authType != null) 'auth_type': authType,
      if (serviceType != null) 'service_type': serviceType,
      if (secretRef != null) 'secret_ref': secretRef,
      if (folderId != null) 'folder_id': folderId,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (rowid != null) 'rowid': rowid,
    });
  }

  IdentitiesCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? username,
    Value<int>? authType,
    Value<String>? serviceType,
    Value<String?>? secretRef,
    Value<String?>? folderId,
    Value<int>? sortOrder,
    Value<int>? rowid,
  }) {
    return IdentitiesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      username: username ?? this.username,
      authType: authType ?? this.authType,
      serviceType: serviceType ?? this.serviceType,
      secretRef: secretRef ?? this.secretRef,
      folderId: folderId ?? this.folderId,
      sortOrder: sortOrder ?? this.sortOrder,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (authType.present) {
      map['auth_type'] = Variable<int>(authType.value);
    }
    if (serviceType.present) {
      map['service_type'] = Variable<String>(serviceType.value);
    }
    if (secretRef.present) {
      map['secret_ref'] = Variable<String>(secretRef.value);
    }
    if (folderId.present) {
      map['folder_id'] = Variable<String>(folderId.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('IdentitiesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('username: $username, ')
          ..write('authType: $authType, ')
          ..write('serviceType: $serviceType, ')
          ..write('secretRef: $secretRef, ')
          ..write('folderId: $folderId, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $KnownHostsTable extends KnownHosts
    with TableInfo<$KnownHostsTable, KnownHostRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KnownHostsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _protocolMeta = const VerificationMeta(
    'protocol',
  );
  @override
  late final GeneratedColumn<String> protocol = GeneratedColumn<String>(
    'protocol',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('ssh'),
  );
  static const VerificationMeta _hostnameMeta = const VerificationMeta(
    'hostname',
  );
  @override
  late final GeneratedColumn<String> hostname = GeneratedColumn<String>(
    'hostname',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
    'port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _keyTypeMeta = const VerificationMeta(
    'keyType',
  );
  @override
  late final GeneratedColumn<String> keyType = GeneratedColumn<String>(
    'key_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fingerprintMeta = const VerificationMeta(
    'fingerprint',
  );
  @override
  late final GeneratedColumn<String> fingerprint = GeneratedColumn<String>(
    'fingerprint',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    protocol,
    hostname,
    port,
    keyType,
    fingerprint,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'known_hosts';
  @override
  VerificationContext validateIntegrity(
    Insertable<KnownHostRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('protocol')) {
      context.handle(
        _protocolMeta,
        protocol.isAcceptableOrUnknown(data['protocol']!, _protocolMeta),
      );
    }
    if (data.containsKey('hostname')) {
      context.handle(
        _hostnameMeta,
        hostname.isAcceptableOrUnknown(data['hostname']!, _hostnameMeta),
      );
    } else if (isInserting) {
      context.missing(_hostnameMeta);
    }
    if (data.containsKey('port')) {
      context.handle(
        _portMeta,
        port.isAcceptableOrUnknown(data['port']!, _portMeta),
      );
    } else if (isInserting) {
      context.missing(_portMeta);
    }
    if (data.containsKey('key_type')) {
      context.handle(
        _keyTypeMeta,
        keyType.isAcceptableOrUnknown(data['key_type']!, _keyTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_keyTypeMeta);
    }
    if (data.containsKey('fingerprint')) {
      context.handle(
        _fingerprintMeta,
        fingerprint.isAcceptableOrUnknown(
          data['fingerprint']!,
          _fingerprintMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_fingerprintMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {hostname, port, protocol};
  @override
  KnownHostRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KnownHostRow(
      protocol: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}protocol'],
      )!,
      hostname: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}hostname'],
      )!,
      port: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}port'],
      )!,
      keyType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key_type'],
      )!,
      fingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fingerprint'],
      )!,
    );
  }

  @override
  $KnownHostsTable createAlias(String alias) {
    return $KnownHostsTable(attachedDatabase, alias);
  }
}

class KnownHostRow extends DataClass implements Insertable<KnownHostRow> {
  final String protocol;
  final String hostname;
  final int port;
  final String keyType;
  final String fingerprint;
  const KnownHostRow({
    required this.protocol,
    required this.hostname,
    required this.port,
    required this.keyType,
    required this.fingerprint,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['protocol'] = Variable<String>(protocol);
    map['hostname'] = Variable<String>(hostname);
    map['port'] = Variable<int>(port);
    map['key_type'] = Variable<String>(keyType);
    map['fingerprint'] = Variable<String>(fingerprint);
    return map;
  }

  KnownHostsCompanion toCompanion(bool nullToAbsent) {
    return KnownHostsCompanion(
      protocol: Value(protocol),
      hostname: Value(hostname),
      port: Value(port),
      keyType: Value(keyType),
      fingerprint: Value(fingerprint),
    );
  }

  factory KnownHostRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KnownHostRow(
      protocol: serializer.fromJson<String>(json['protocol']),
      hostname: serializer.fromJson<String>(json['hostname']),
      port: serializer.fromJson<int>(json['port']),
      keyType: serializer.fromJson<String>(json['keyType']),
      fingerprint: serializer.fromJson<String>(json['fingerprint']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'protocol': serializer.toJson<String>(protocol),
      'hostname': serializer.toJson<String>(hostname),
      'port': serializer.toJson<int>(port),
      'keyType': serializer.toJson<String>(keyType),
      'fingerprint': serializer.toJson<String>(fingerprint),
    };
  }

  KnownHostRow copyWith({
    String? protocol,
    String? hostname,
    int? port,
    String? keyType,
    String? fingerprint,
  }) => KnownHostRow(
    protocol: protocol ?? this.protocol,
    hostname: hostname ?? this.hostname,
    port: port ?? this.port,
    keyType: keyType ?? this.keyType,
    fingerprint: fingerprint ?? this.fingerprint,
  );
  KnownHostRow copyWithCompanion(KnownHostsCompanion data) {
    return KnownHostRow(
      protocol: data.protocol.present ? data.protocol.value : this.protocol,
      hostname: data.hostname.present ? data.hostname.value : this.hostname,
      port: data.port.present ? data.port.value : this.port,
      keyType: data.keyType.present ? data.keyType.value : this.keyType,
      fingerprint: data.fingerprint.present
          ? data.fingerprint.value
          : this.fingerprint,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KnownHostRow(')
          ..write('protocol: $protocol, ')
          ..write('hostname: $hostname, ')
          ..write('port: $port, ')
          ..write('keyType: $keyType, ')
          ..write('fingerprint: $fingerprint')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(protocol, hostname, port, keyType, fingerprint);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KnownHostRow &&
          other.protocol == this.protocol &&
          other.hostname == this.hostname &&
          other.port == this.port &&
          other.keyType == this.keyType &&
          other.fingerprint == this.fingerprint);
}

class KnownHostsCompanion extends UpdateCompanion<KnownHostRow> {
  final Value<String> protocol;
  final Value<String> hostname;
  final Value<int> port;
  final Value<String> keyType;
  final Value<String> fingerprint;
  final Value<int> rowid;
  const KnownHostsCompanion({
    this.protocol = const Value.absent(),
    this.hostname = const Value.absent(),
    this.port = const Value.absent(),
    this.keyType = const Value.absent(),
    this.fingerprint = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KnownHostsCompanion.insert({
    this.protocol = const Value.absent(),
    required String hostname,
    required int port,
    required String keyType,
    required String fingerprint,
    this.rowid = const Value.absent(),
  }) : hostname = Value(hostname),
       port = Value(port),
       keyType = Value(keyType),
       fingerprint = Value(fingerprint);
  static Insertable<KnownHostRow> custom({
    Expression<String>? protocol,
    Expression<String>? hostname,
    Expression<int>? port,
    Expression<String>? keyType,
    Expression<String>? fingerprint,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (protocol != null) 'protocol': protocol,
      if (hostname != null) 'hostname': hostname,
      if (port != null) 'port': port,
      if (keyType != null) 'key_type': keyType,
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KnownHostsCompanion copyWith({
    Value<String>? protocol,
    Value<String>? hostname,
    Value<int>? port,
    Value<String>? keyType,
    Value<String>? fingerprint,
    Value<int>? rowid,
  }) {
    return KnownHostsCompanion(
      protocol: protocol ?? this.protocol,
      hostname: hostname ?? this.hostname,
      port: port ?? this.port,
      keyType: keyType ?? this.keyType,
      fingerprint: fingerprint ?? this.fingerprint,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (protocol.present) {
      map['protocol'] = Variable<String>(protocol.value);
    }
    if (hostname.present) {
      map['hostname'] = Variable<String>(hostname.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (keyType.present) {
      map['key_type'] = Variable<String>(keyType.value);
    }
    if (fingerprint.present) {
      map['fingerprint'] = Variable<String>(fingerprint.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KnownHostsCompanion(')
          ..write('protocol: $protocol, ')
          ..write('hostname: $hostname, ')
          ..write('port: $port, ')
          ..write('keyType: $keyType, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AppSettingsTable extends AppSettings
    with TableInfo<$AppSettingsTable, AppSetting> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppSettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'app_settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppSetting> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  AppSetting map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppSetting(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $AppSettingsTable createAlias(String alias) {
    return $AppSettingsTable(attachedDatabase, alias);
  }
}

class AppSetting extends DataClass implements Insertable<AppSetting> {
  final String key;
  final String value;
  const AppSetting({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  AppSettingsCompanion toCompanion(bool nullToAbsent) {
    return AppSettingsCompanion(key: Value(key), value: Value(value));
  }

  factory AppSetting.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppSetting(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  AppSetting copyWith({String? key, String? value}) =>
      AppSetting(key: key ?? this.key, value: value ?? this.value);
  AppSetting copyWithCompanion(AppSettingsCompanion data) {
    return AppSetting(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppSetting(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppSetting &&
          other.key == this.key &&
          other.value == this.value);
}

class AppSettingsCompanion extends UpdateCompanion<AppSetting> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const AppSettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppSettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<AppSetting> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppSettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return AppSettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AppSettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $FoldersTable folders = $FoldersTable(this);
  late final $IdentityFoldersTable identityFolders = $IdentityFoldersTable(
    this,
  );
  late final $HostsTable hosts = $HostsTable(this);
  late final $IdentitiesTable identities = $IdentitiesTable(this);
  late final $KnownHostsTable knownHosts = $KnownHostsTable(this);
  late final $AppSettingsTable appSettings = $AppSettingsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    folders,
    identityFolders,
    hosts,
    identities,
    knownHosts,
    appSettings,
  ];
}

typedef $$FoldersTableCreateCompanionBuilder = FoldersCompanion Function({
  Value<bool> isGateway,
  required String id,
  required String name,
  Value<String?> parentId,
  Value<int> sortOrder,
  Value<int> rowid,
});
typedef $$FoldersTableUpdateCompanionBuilder = FoldersCompanion Function({
  Value<bool> isGateway,
  Value<String> id,
  Value<String> name,
  Value<String?> parentId,
  Value<int> sortOrder,
  Value<int> rowid,
});

class $$FoldersTableFilterComposer
    extends Composer<_$AppDatabase, $FoldersTable> {
  $$FoldersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<bool> get isGateway => $composableBuilder(
    column: $table.isGateway,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );
}

class $$FoldersTableOrderingComposer
    extends Composer<_$AppDatabase, $FoldersTable> {
  $$FoldersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<bool> get isGateway => $composableBuilder(
    column: $table.isGateway,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$FoldersTableAnnotationComposer
    extends Composer<_$AppDatabase, $FoldersTable> {
  $$FoldersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<bool> get isGateway =>
      $composableBuilder(column: $table.isGateway, builder: (column) => column);

  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);
}

class $$FoldersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $FoldersTable,
          FolderRow,
          $$FoldersTableFilterComposer,
          $$FoldersTableOrderingComposer,
          $$FoldersTableAnnotationComposer,
          $$FoldersTableCreateCompanionBuilder,
          $$FoldersTableUpdateCompanionBuilder,
          (FolderRow, BaseReferences<_$AppDatabase, $FoldersTable, FolderRow>),
          FolderRow,
          PrefetchHooks Function()
        > {
  $$FoldersTableTableManager(_$AppDatabase db, $FoldersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FoldersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FoldersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FoldersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<bool> isGateway = const Value.absent(),
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> parentId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FoldersCompanion(
                isGateway: isGateway,
                id: id,
                name: name,
                parentId: parentId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<bool> isGateway = const Value.absent(),
                required String id,
                required String name,
                Value<String?> parentId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FoldersCompanion.insert(
                isGateway: isGateway,
                id: id,
                name: name,
                parentId: parentId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$FoldersTable, FolderRow>(table),
                  BaseReferences<_$AppDatabase, $FoldersTable, FolderRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$FoldersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $FoldersTable,
      FolderRow,
      $$FoldersTableFilterComposer,
      $$FoldersTableOrderingComposer,
      $$FoldersTableAnnotationComposer,
      $$FoldersTableCreateCompanionBuilder,
      $$FoldersTableUpdateCompanionBuilder,
      (FolderRow, BaseReferences<_$AppDatabase, $FoldersTable, FolderRow>),
      FolderRow,
      PrefetchHooks Function()
    >;
typedef $$IdentityFoldersTableCreateCompanionBuilder =
    IdentityFoldersCompanion Function({
      required String id,
      required String name,
      Value<String?> parentId,
      Value<int> sortOrder,
      Value<int> rowid,
    });
typedef $$IdentityFoldersTableUpdateCompanionBuilder =
    IdentityFoldersCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String?> parentId,
      Value<int> sortOrder,
      Value<int> rowid,
    });

class $$IdentityFoldersTableFilterComposer
    extends Composer<_$AppDatabase, $IdentityFoldersTable> {
  $$IdentityFoldersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );
}

class $$IdentityFoldersTableOrderingComposer
    extends Composer<_$AppDatabase, $IdentityFoldersTable> {
  $$IdentityFoldersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$IdentityFoldersTableAnnotationComposer
    extends Composer<_$AppDatabase, $IdentityFoldersTable> {
  $$IdentityFoldersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);
}

class $$IdentityFoldersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $IdentityFoldersTable,
          IdentityFolderRow,
          $$IdentityFoldersTableFilterComposer,
          $$IdentityFoldersTableOrderingComposer,
          $$IdentityFoldersTableAnnotationComposer,
          $$IdentityFoldersTableCreateCompanionBuilder,
          $$IdentityFoldersTableUpdateCompanionBuilder,
          (
            IdentityFolderRow,
            BaseReferences<
              _$AppDatabase,
              $IdentityFoldersTable,
              IdentityFolderRow
            >,
          ),
          IdentityFolderRow,
          PrefetchHooks Function()
        > {
  $$IdentityFoldersTableTableManager(
    _$AppDatabase db,
    $IdentityFoldersTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$IdentityFoldersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$IdentityFoldersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$IdentityFoldersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> parentId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => IdentityFoldersCompanion(
                id: id,
                name: name,
                parentId: parentId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<String?> parentId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => IdentityFoldersCompanion.insert(
                id: id,
                name: name,
                parentId: parentId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$IdentityFoldersTable, IdentityFolderRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $IdentityFoldersTable,
                    IdentityFolderRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$IdentityFoldersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $IdentityFoldersTable,
      IdentityFolderRow,
      $$IdentityFoldersTableFilterComposer,
      $$IdentityFoldersTableOrderingComposer,
      $$IdentityFoldersTableAnnotationComposer,
      $$IdentityFoldersTableCreateCompanionBuilder,
      $$IdentityFoldersTableUpdateCompanionBuilder,
      (
        IdentityFolderRow,
        BaseReferences<_$AppDatabase, $IdentityFoldersTable, IdentityFolderRow>,
      ),
      IdentityFolderRow,
      PrefetchHooks Function()
    >;
typedef $$HostsTableCreateCompanionBuilder = HostsCompanion Function({
  Value<bool> isGateway,
  Value<String?> gatewayId,
  Value<String> gatewayType,
  Value<String> rdpDomain,
  Value<String> pageClientId,
  Value<String> pageServerFingerprint,
  required String id,
  required String name,
  required String hostname,
  Value<int> port,
  Value<String> username,
  Value<String> note,
  Value<String> tags,
  Value<String?> folderId,
  Value<String?> identityId,
  Value<int?> colorValue,
  Value<int> sortOrder,
  Value<String> forwardPortsJson,
  Value<String> proxyConfigJson,
  Value<int> rowid,
});
typedef $$HostsTableUpdateCompanionBuilder = HostsCompanion Function({
  Value<bool> isGateway,
  Value<String?> gatewayId,
  Value<String> gatewayType,
  Value<String> rdpDomain,
  Value<String> pageClientId,
  Value<String> pageServerFingerprint,
  Value<String> id,
  Value<String> name,
  Value<String> hostname,
  Value<int> port,
  Value<String> username,
  Value<String> note,
  Value<String> tags,
  Value<String?> folderId,
  Value<String?> identityId,
  Value<int?> colorValue,
  Value<int> sortOrder,
  Value<String> forwardPortsJson,
  Value<String> proxyConfigJson,
  Value<int> rowid,
});

class $$HostsTableFilterComposer extends Composer<_$AppDatabase, $HostsTable> {
  $$HostsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<bool> get isGateway => $composableBuilder(
    column: $table.isGateway,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get gatewayId => $composableBuilder(
    column: $table.gatewayId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get gatewayType => $composableBuilder(
    column: $table.gatewayType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get rdpDomain => $composableBuilder(
    column: $table.rdpDomain,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pageClientId => $composableBuilder(
    column: $table.pageClientId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pageServerFingerprint => $composableBuilder(
    column: $table.pageServerFingerprint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get hostname => $composableBuilder(
    column: $table.hostname,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get identityId => $composableBuilder(
    column: $table.identityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get forwardPortsJson => $composableBuilder(
    column: $table.forwardPortsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get proxyConfigJson => $composableBuilder(
    column: $table.proxyConfigJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$HostsTableOrderingComposer
    extends Composer<_$AppDatabase, $HostsTable> {
  $$HostsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<bool> get isGateway => $composableBuilder(
    column: $table.isGateway,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get gatewayId => $composableBuilder(
    column: $table.gatewayId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get gatewayType => $composableBuilder(
    column: $table.gatewayType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get rdpDomain => $composableBuilder(
    column: $table.rdpDomain,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pageClientId => $composableBuilder(
    column: $table.pageClientId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pageServerFingerprint => $composableBuilder(
    column: $table.pageServerFingerprint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get hostname => $composableBuilder(
    column: $table.hostname,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get identityId => $composableBuilder(
    column: $table.identityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get forwardPortsJson => $composableBuilder(
    column: $table.forwardPortsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get proxyConfigJson => $composableBuilder(
    column: $table.proxyConfigJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$HostsTableAnnotationComposer
    extends Composer<_$AppDatabase, $HostsTable> {
  $$HostsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<bool> get isGateway =>
      $composableBuilder(column: $table.isGateway, builder: (column) => column);

  GeneratedColumn<String> get gatewayId =>
      $composableBuilder(column: $table.gatewayId, builder: (column) => column);

  GeneratedColumn<String> get gatewayType => $composableBuilder(
    column: $table.gatewayType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get rdpDomain =>
      $composableBuilder(column: $table.rdpDomain, builder: (column) => column);

  GeneratedColumn<String> get pageClientId => $composableBuilder(
    column: $table.pageClientId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get pageServerFingerprint => $composableBuilder(
    column: $table.pageServerFingerprint,
    builder: (column) => column,
  );

  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get hostname =>
      $composableBuilder(column: $table.hostname, builder: (column) => column);

  GeneratedColumn<int> get port =>
      $composableBuilder(column: $table.port, builder: (column) => column);

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<String> get tags =>
      $composableBuilder(column: $table.tags, builder: (column) => column);

  GeneratedColumn<String> get folderId =>
      $composableBuilder(column: $table.folderId, builder: (column) => column);

  GeneratedColumn<String> get identityId => $composableBuilder(
    column: $table.identityId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get colorValue => $composableBuilder(
    column: $table.colorValue,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<String> get forwardPortsJson => $composableBuilder(
    column: $table.forwardPortsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get proxyConfigJson => $composableBuilder(
    column: $table.proxyConfigJson,
    builder: (column) => column,
  );
}

class $$HostsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $HostsTable,
          HostRow,
          $$HostsTableFilterComposer,
          $$HostsTableOrderingComposer,
          $$HostsTableAnnotationComposer,
          $$HostsTableCreateCompanionBuilder,
          $$HostsTableUpdateCompanionBuilder,
          (HostRow, BaseReferences<_$AppDatabase, $HostsTable, HostRow>),
          HostRow,
          PrefetchHooks Function()
        > {
  $$HostsTableTableManager(_$AppDatabase db, $HostsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HostsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HostsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HostsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<bool> isGateway = const Value.absent(),
                Value<String?> gatewayId = const Value.absent(),
                Value<String> gatewayType = const Value.absent(),
                Value<String> rdpDomain = const Value.absent(),
                Value<String> pageClientId = const Value.absent(),
                Value<String> pageServerFingerprint = const Value.absent(),
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> hostname = const Value.absent(),
                Value<int> port = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String> note = const Value.absent(),
                Value<String> tags = const Value.absent(),
                Value<String?> folderId = const Value.absent(),
                Value<String?> identityId = const Value.absent(),
                Value<int?> colorValue = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<String> forwardPortsJson = const Value.absent(),
                Value<String> proxyConfigJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HostsCompanion(
                isGateway: isGateway,
                gatewayId: gatewayId,
                gatewayType: gatewayType,
                rdpDomain: rdpDomain,
                pageClientId: pageClientId,
                pageServerFingerprint: pageServerFingerprint,
                id: id,
                name: name,
                hostname: hostname,
                port: port,
                username: username,
                note: note,
                tags: tags,
                folderId: folderId,
                identityId: identityId,
                colorValue: colorValue,
                sortOrder: sortOrder,
                forwardPortsJson: forwardPortsJson,
                proxyConfigJson: proxyConfigJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<bool> isGateway = const Value.absent(),
                Value<String?> gatewayId = const Value.absent(),
                Value<String> gatewayType = const Value.absent(),
                Value<String> rdpDomain = const Value.absent(),
                Value<String> pageClientId = const Value.absent(),
                Value<String> pageServerFingerprint = const Value.absent(),
                required String id,
                required String name,
                required String hostname,
                Value<int> port = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String> note = const Value.absent(),
                Value<String> tags = const Value.absent(),
                Value<String?> folderId = const Value.absent(),
                Value<String?> identityId = const Value.absent(),
                Value<int?> colorValue = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<String> forwardPortsJson = const Value.absent(),
                Value<String> proxyConfigJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HostsCompanion.insert(
                isGateway: isGateway,
                gatewayId: gatewayId,
                gatewayType: gatewayType,
                rdpDomain: rdpDomain,
                pageClientId: pageClientId,
                pageServerFingerprint: pageServerFingerprint,
                id: id,
                name: name,
                hostname: hostname,
                port: port,
                username: username,
                note: note,
                tags: tags,
                folderId: folderId,
                identityId: identityId,
                colorValue: colorValue,
                sortOrder: sortOrder,
                forwardPortsJson: forwardPortsJson,
                proxyConfigJson: proxyConfigJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$HostsTable, HostRow>(table),
                  BaseReferences<_$AppDatabase, $HostsTable, HostRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$HostsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $HostsTable,
      HostRow,
      $$HostsTableFilterComposer,
      $$HostsTableOrderingComposer,
      $$HostsTableAnnotationComposer,
      $$HostsTableCreateCompanionBuilder,
      $$HostsTableUpdateCompanionBuilder,
      (HostRow, BaseReferences<_$AppDatabase, $HostsTable, HostRow>),
      HostRow,
      PrefetchHooks Function()
    >;
typedef $$IdentitiesTableCreateCompanionBuilder = IdentitiesCompanion Function({
  required String id,
  required String name,
  required String username,
  Value<int> authType,
  Value<String> serviceType,
  Value<String?> secretRef,
  Value<String?> folderId,
  Value<int> sortOrder,
  Value<int> rowid,
});
typedef $$IdentitiesTableUpdateCompanionBuilder = IdentitiesCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<String> username,
  Value<int> authType,
  Value<String> serviceType,
  Value<String?> secretRef,
  Value<String?> folderId,
  Value<int> sortOrder,
  Value<int> rowid,
});

class $$IdentitiesTableFilterComposer
    extends Composer<_$AppDatabase, $IdentitiesTable> {
  $$IdentitiesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get authType => $composableBuilder(
    column: $table.authType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serviceType => $composableBuilder(
    column: $table.serviceType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get secretRef => $composableBuilder(
    column: $table.secretRef,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );
}

class $$IdentitiesTableOrderingComposer
    extends Composer<_$AppDatabase, $IdentitiesTable> {
  $$IdentitiesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get authType => $composableBuilder(
    column: $table.authType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serviceType => $composableBuilder(
    column: $table.serviceType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get secretRef => $composableBuilder(
    column: $table.secretRef,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get folderId => $composableBuilder(
    column: $table.folderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$IdentitiesTableAnnotationComposer
    extends Composer<_$AppDatabase, $IdentitiesTable> {
  $$IdentitiesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<int> get authType =>
      $composableBuilder(column: $table.authType, builder: (column) => column);

  GeneratedColumn<String> get serviceType => $composableBuilder(
    column: $table.serviceType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get secretRef =>
      $composableBuilder(column: $table.secretRef, builder: (column) => column);

  GeneratedColumn<String> get folderId =>
      $composableBuilder(column: $table.folderId, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);
}

class $$IdentitiesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $IdentitiesTable,
          IdentityRow,
          $$IdentitiesTableFilterComposer,
          $$IdentitiesTableOrderingComposer,
          $$IdentitiesTableAnnotationComposer,
          $$IdentitiesTableCreateCompanionBuilder,
          $$IdentitiesTableUpdateCompanionBuilder,
          (
            IdentityRow,
            BaseReferences<_$AppDatabase, $IdentitiesTable, IdentityRow>,
          ),
          IdentityRow,
          PrefetchHooks Function()
        > {
  $$IdentitiesTableTableManager(_$AppDatabase db, $IdentitiesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$IdentitiesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$IdentitiesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$IdentitiesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<int> authType = const Value.absent(),
                Value<String> serviceType = const Value.absent(),
                Value<String?> secretRef = const Value.absent(),
                Value<String?> folderId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => IdentitiesCompanion(
                id: id,
                name: name,
                username: username,
                authType: authType,
                serviceType: serviceType,
                secretRef: secretRef,
                folderId: folderId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String username,
                Value<int> authType = const Value.absent(),
                Value<String> serviceType = const Value.absent(),
                Value<String?> secretRef = const Value.absent(),
                Value<String?> folderId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => IdentitiesCompanion.insert(
                id: id,
                name: name,
                username: username,
                authType: authType,
                serviceType: serviceType,
                secretRef: secretRef,
                folderId: folderId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$IdentitiesTable, IdentityRow>(table),
                  BaseReferences<_$AppDatabase, $IdentitiesTable, IdentityRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$IdentitiesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $IdentitiesTable,
      IdentityRow,
      $$IdentitiesTableFilterComposer,
      $$IdentitiesTableOrderingComposer,
      $$IdentitiesTableAnnotationComposer,
      $$IdentitiesTableCreateCompanionBuilder,
      $$IdentitiesTableUpdateCompanionBuilder,
      (
        IdentityRow,
        BaseReferences<_$AppDatabase, $IdentitiesTable, IdentityRow>,
      ),
      IdentityRow,
      PrefetchHooks Function()
    >;
typedef $$KnownHostsTableCreateCompanionBuilder = KnownHostsCompanion Function({
  Value<String> protocol,
  required String hostname,
  required int port,
  required String keyType,
  required String fingerprint,
  Value<int> rowid,
});
typedef $$KnownHostsTableUpdateCompanionBuilder = KnownHostsCompanion Function({
  Value<String> protocol,
  Value<String> hostname,
  Value<int> port,
  Value<String> keyType,
  Value<String> fingerprint,
  Value<int> rowid,
});

class $$KnownHostsTableFilterComposer
    extends Composer<_$AppDatabase, $KnownHostsTable> {
  $$KnownHostsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get protocol => $composableBuilder(
    column: $table.protocol,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get hostname => $composableBuilder(
    column: $table.hostname,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get keyType => $composableBuilder(
    column: $table.keyType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnFilters(column),
  );
}

class $$KnownHostsTableOrderingComposer
    extends Composer<_$AppDatabase, $KnownHostsTable> {
  $$KnownHostsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get protocol => $composableBuilder(
    column: $table.protocol,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get hostname => $composableBuilder(
    column: $table.hostname,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get keyType => $composableBuilder(
    column: $table.keyType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$KnownHostsTableAnnotationComposer
    extends Composer<_$AppDatabase, $KnownHostsTable> {
  $$KnownHostsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get protocol =>
      $composableBuilder(column: $table.protocol, builder: (column) => column);

  GeneratedColumn<String> get hostname =>
      $composableBuilder(column: $table.hostname, builder: (column) => column);

  GeneratedColumn<int> get port =>
      $composableBuilder(column: $table.port, builder: (column) => column);

  GeneratedColumn<String> get keyType =>
      $composableBuilder(column: $table.keyType, builder: (column) => column);

  GeneratedColumn<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => column,
  );
}

class $$KnownHostsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $KnownHostsTable,
          KnownHostRow,
          $$KnownHostsTableFilterComposer,
          $$KnownHostsTableOrderingComposer,
          $$KnownHostsTableAnnotationComposer,
          $$KnownHostsTableCreateCompanionBuilder,
          $$KnownHostsTableUpdateCompanionBuilder,
          (
            KnownHostRow,
            BaseReferences<_$AppDatabase, $KnownHostsTable, KnownHostRow>,
          ),
          KnownHostRow,
          PrefetchHooks Function()
        > {
  $$KnownHostsTableTableManager(_$AppDatabase db, $KnownHostsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$KnownHostsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$KnownHostsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$KnownHostsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> protocol = const Value.absent(),
                Value<String> hostname = const Value.absent(),
                Value<int> port = const Value.absent(),
                Value<String> keyType = const Value.absent(),
                Value<String> fingerprint = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KnownHostsCompanion(
                protocol: protocol,
                hostname: hostname,
                port: port,
                keyType: keyType,
                fingerprint: fingerprint,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                Value<String> protocol = const Value.absent(),
                required String hostname,
                required int port,
                required String keyType,
                required String fingerprint,
                Value<int> rowid = const Value.absent(),
              }) => KnownHostsCompanion.insert(
                protocol: protocol,
                hostname: hostname,
                port: port,
                keyType: keyType,
                fingerprint: fingerprint,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$KnownHostsTable, KnownHostRow>(table),
                  BaseReferences<_$AppDatabase, $KnownHostsTable, KnownHostRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KnownHostsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $KnownHostsTable,
      KnownHostRow,
      $$KnownHostsTableFilterComposer,
      $$KnownHostsTableOrderingComposer,
      $$KnownHostsTableAnnotationComposer,
      $$KnownHostsTableCreateCompanionBuilder,
      $$KnownHostsTableUpdateCompanionBuilder,
      (
        KnownHostRow,
        BaseReferences<_$AppDatabase, $KnownHostsTable, KnownHostRow>,
      ),
      KnownHostRow,
      PrefetchHooks Function()
    >;
typedef $$AppSettingsTableCreateCompanionBuilder =
    AppSettingsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$AppSettingsTableUpdateCompanionBuilder =
    AppSettingsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$AppSettingsTableFilterComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AppSettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppSettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$AppSettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AppSettingsTable,
          AppSetting,
          $$AppSettingsTableFilterComposer,
          $$AppSettingsTableOrderingComposer,
          $$AppSettingsTableAnnotationComposer,
          $$AppSettingsTableCreateCompanionBuilder,
          $$AppSettingsTableUpdateCompanionBuilder,
          (
            AppSetting,
            BaseReferences<_$AppDatabase, $AppSettingsTable, AppSetting>,
          ),
          AppSetting,
          PrefetchHooks Function()
        > {
  $$AppSettingsTableTableManager(_$AppDatabase db, $AppSettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => AppSettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => AppSettingsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AppSettingsTable, AppSetting>(table),
                  BaseReferences<_$AppDatabase, $AppSettingsTable, AppSetting>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppSettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AppSettingsTable,
      AppSetting,
      $$AppSettingsTableFilterComposer,
      $$AppSettingsTableOrderingComposer,
      $$AppSettingsTableAnnotationComposer,
      $$AppSettingsTableCreateCompanionBuilder,
      $$AppSettingsTableUpdateCompanionBuilder,
      (
        AppSetting,
        BaseReferences<_$AppDatabase, $AppSettingsTable, AppSetting>,
      ),
      AppSetting,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$FoldersTableTableManager get folders =>
      $$FoldersTableTableManager(_db, _db.folders);
  $$IdentityFoldersTableTableManager get identityFolders =>
      $$IdentityFoldersTableTableManager(_db, _db.identityFolders);
  $$HostsTableTableManager get hosts =>
      $$HostsTableTableManager(_db, _db.hosts);
  $$IdentitiesTableTableManager get identities =>
      $$IdentitiesTableTableManager(_db, _db.identities);
  $$KnownHostsTableTableManager get knownHosts =>
      $$KnownHostsTableTableManager(_db, _db.knownHosts);
  $$AppSettingsTableTableManager get appSettings =>
      $$AppSettingsTableTableManager(_db, _db.appSettings);
}
