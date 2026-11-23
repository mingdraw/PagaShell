part of 'sidebar.dart';

typedef _TreeRow = ({Key key, Widget Function() build});
typedef _TreeTransition = ({_TreeRow row, double from, bool visible});

extension _SidebarTree on SidebarStateView {
  Widget _tree() {
    final hosts = Get.find<HostTreeController>();
    final identities = Get.find<IdentityTreeController>();
    final gateways = Get.isRegistered<GatewayTreeController>()
        ? Get.find<GatewayTreeController>()
        : null;
    return CustomScrollView(
      key: _treeViewport,
      controller: _treeScroll,
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 4)),
        _hostHeader(hosts, SidebarSection.services, _dragAnchor),
        _hostRows(hosts, SidebarSection.services, _dragAnchor),
        const SliverToBoxAdapter(child: SizedBox(height: 4)),
        _identityHeader(identities),
        _identityRows(identities),
        if (gateways != null) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 4)),
          _hostHeader(gateways, SidebarSection.gateways, _gatewayDragAnchor),
          _hostRows(gateways, SidebarSection.gateways, _gatewayDragAnchor),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 4)),
      ],
    );
  }

  Widget _hostHeader(
    HostTreeController tree,
    SidebarSection section,
    TreeDragAnchor dragAnchor,
  ) => SliverToBoxAdapter(
    child: Obx(() {
      final expanded = _settings.isSidebarSectionExpanded(section);
      final count = tree.hosts.hosts.length;
      final gateway = section == SidebarSection.gateways;
      const placement = HostTreePlacement(parentId: null);
      return _RootDropTarget<HostTreeItem>(
        canDrop: (item) => tree.canMove(item, placement),
        onDrop: (item) {
          if (dragAnchor.scrolledSinceMove) return;
          _setGroupExpanded(section, true);
          unawaited(moveHostTreeItem(tree, item, placement));
        },
        child: _SectionHeader(
          icon: gateway ? AppIcons.network : AppIcons.server,
          title: (gateway ? '网关' : '服务').tr,
          count: count,
          expanded: expanded,
          onToggle: () => _setGroupExpanded(section, !expanded),
          menuSemanticLabel: (gateway ? '网关组操作' : '服务组操作').tr,
          actions: [
            if (gateway)
              ('new-gateway', '新建网关'.tr)
            else
              ('new-host', '新建服务'.tr),
            ('new-folder', '新建文件夹'.tr),
          ],
          onAction: gateway
              ? (action) {
                  if (action == 'new-gateway') {
                    unawaited(showHostEditDialog(context, gateway: true));
                  } else if (action == 'new-folder') {
                    unawaited(
                      showFolderDialog(context, folderController: tree.folders),
                    );
                  }
                }
              : _onHostsGroupAction,
        ),
      );
    }),
  );

  Widget _identityHeader(IdentityTreeController tree) => SliverToBoxAdapter(
    child: Obx(() {
      const section = SidebarSection.identities;
      final expanded = _settings.isSidebarSectionExpanded(section);
      final count = tree.identities.identities.length;
      const placement = IdentityTreePlacement(parentId: null);
      return _RootDropTarget<IdentityTreeItem>(
        canDrop: (item) => tree.canMove(item, placement),
        onDrop: (item) {
          if (_identityDragAnchor.scrolledSinceMove) return;
          _setGroupExpanded(section, true);
          unawaited(moveIdentityTreeItem(tree, item, placement));
        },
        child: _SectionHeader(
          icon: AppIcons.bookKey,
          title: '凭证'.tr,
          count: count,
          expanded: expanded,
          onToggle: () => _setGroupExpanded(section, !expanded),
          menuSemanticLabel: '凭证组操作'.tr,
          actions: [('new-identity', '新建凭证'.tr), ('new-folder', '新建文件夹'.tr)],
          onAction: _onIdentitiesGroupAction,
        ),
      );
    }),
  );

  Widget _hostRows(
    HostTreeController tree,
    SidebarSection section,
    TreeDragAnchor dragAnchor,
  ) => Obx(() {
    final snapshot = tree.snapshot;
    final expanded = _settings.isSidebarSectionExpanded(section);
    final gateway = section == SidebarSection.gateways;
    final rows = <_TreeRow>[];
    if (expanded) {
      void visit(String? parent, int depth) {
        for (final node in snapshot.childrenOf(parent)) {
          final key = ValueKey(node.item);
          if (node.folder case final folder?) {
            final open = tree.folders.isExpanded(folder.id);
            rows.add((
              key: key,
              build: () => _FolderTile(
                folder: folder,
                containsGateways: gateway,
                depth: depth,
                expanded: open,
                childCount: snapshot.childCount(folder.id),
                dragAnchor: dragAnchor,
              ),
            ));
            if (open) visit(folder.id, depth + 1);
          } else {
            final host = node.host!;
            rows.add((
              key: key,
              build: () => _HostTile(
                host: host,
                depth: depth,
                gateway: gateway,
                dragAnchor: dragAnchor,
              ),
            ));
          }
        }
      }

      visit(null, 1);
      if (gateway ? tree.hosts.hosts.isEmpty : rows.isEmpty) {
        rows.add((
          key: const ValueKey('empty-host-tree'),
          build: () =>
              _EmptyTreeHint(label: gateway ? '还没有网关，可通过组菜单新建' : '还没有服务'),
        ));
      }
    }
    return _SidebarTreeSliver(source: snapshot, rows: rows);
  });

  Widget _identityRows(IdentityTreeController tree) => Obx(() {
    final snapshot = tree.snapshot;
    final rows = <_TreeRow>[];
    if (_settings.isSidebarSectionExpanded(SidebarSection.identities)) {
      void visit(String? parent, int depth) {
        for (final node in snapshot.childrenOf(parent)) {
          final key = ValueKey(node.item);
          if (node.folder case final folder?) {
            final open = tree.folders.isExpanded(folder.id);
            rows.add((
              key: key,
              build: () => _FolderTile(
                folder: folder,
                containsIdentities: true,
                depth: depth,
                expanded: open,
                childCount: snapshot.childCount(folder.id),
                dragAnchor: _identityDragAnchor,
              ),
            ));
            if (open) visit(folder.id, depth + 1);
          } else {
            final identity = node.identity!;
            rows.add((
              key: key,
              build: () => _IdentityTile(
                identity: identity,
                depth: depth,
                dragAnchor: _identityDragAnchor,
              ),
            ));
          }
        }
      }

      visit(null, 1);
      if (rows.isEmpty) {
        rows.add((
          key: const ValueKey('empty-identity-tree'),
          build: () => const _EmptyTreeHint(label: '还没有凭证，连接服务时可保存'),
        ));
      }
    }
    return _SidebarTreeSliver(source: snapshot, rows: rows);
  });
}

class _RootDropTarget<T extends Object> extends StatelessWidget {
  const _RootDropTarget({
    required this.canDrop,
    required this.onDrop,
    required this.child,
  });

  final bool Function(T) canDrop;
  final ValueChanged<T> onDrop;
  final Widget child;

  @override
  Widget build(BuildContext context) => DragTarget<T>(
    onWillAcceptWithDetails: (details) => canDrop(details.data),
    onAcceptWithDetails: (details) => onDrop(details.data),
    builder: (context, candidates, _) => ColoredBox(
      color: candidates.isEmpty
          ? shadcn.Colors.transparent
          : shadcn.Theme.of(context).colorScheme.primary
                .withValues(alpha: 0.12),
      child: child,
    ),
  );
}

class _EmptyTreeHint extends StatelessWidget {
  const _EmptyTreeHint({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 8, 12, 8),
    child: Text(
      label.tr,
      style: TextStyle(
        fontSize: 12,
        color: shadcn.Theme.of(context).colorScheme.mutedForeground,
      ),
    ),
  );
}

class _SidebarTreeSliver extends StatefulWidget {
  const _SidebarTreeSliver({required this.source, required this.rows});

  final Object source;
  final List<_TreeRow> rows;

  @override
  State<_SidebarTreeSliver> createState() => _SidebarTreeSliverState();
}

class _SidebarTreeSliverState extends State<_SidebarTreeSliver>
    with SingleTickerProviderStateMixin {
  // Bound the number of zero-height rows the sliver can lay out in one frame.
  // Changes beyond these leading rows take effect without a size transition.
  static const _animatedRowsLimit = 24;
  late final AnimationController _animation;
  late List<_TreeTransition> _rows = _steadyRows();
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    _animation =
        AnimationController(
          vsync: this,
          duration: AppTheme.sidebarTransitionDuration,
          value: 1,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) setState(_settle);
        });
  }

  List<_TreeTransition> _steadyRows() => [
    for (final row in widget.rows) (row: row, from: 1, visible: true),
  ];

  void _settle() => _rows = _steadyRows();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations) {
      _animation.stop();
      _settle();
    }
  }

  @override
  void didUpdateWidget(covariant _SidebarTreeSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_disableAnimations || !identical(widget.source, oldWidget.source)) {
      _animation.stop();
      _settle();
      return;
    }
    final previous = {for (final row in _rows) row.row.key: row};
    final incoming = {for (final row in widget.rows) row.key};
    final progress = Curves.easeInOutCubic.transform(_animation.value);
    final next = <_TreeTransition>[];
    var remaining = _animatedRowsLimit;
    var offset = 0;

    void append(_TreeRow row, _TreeTransition? old, {required bool visible}) {
      final from = old == null ? 0.0 : _rowSize(old, progress);
      if (visible ? from < 1 : from > 0) {
        if (remaining > 0) {
          remaining--;
          next.add((row: row, from: from, visible: visible));
          return;
        }
      }
      if (visible) next.add((row: row, from: 1, visible: true));
    }

    void removeUntil(Key? key) {
      while (offset < _rows.length && _rows[offset].row.key != key) {
        final old = _rows[offset++];
        if (!incoming.contains(old.row.key)) {
          append(old.row, old, visible: false);
        }
      }
    }

    // The order of shared rows is stable when only expansion flags change.
    for (final row in widget.rows) {
      final old = previous[row.key];
      if (old != null) {
        removeUntil(row.key);
        offset++;
      }
      append(row, old, visible: true);
    }
    removeUntil(null);
    _rows = next;
    if (remaining < _animatedRowsLimit) {
      _animation.forward(from: 0);
    } else {
      _animation.stop();
    }
  }

  static double _rowSize(_TreeTransition row, double progress) => row.visible
      ? row.from + (1 - row.from) * progress
      : row.from * (1 - progress);

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].row.key: i};
    return SliverList.builder(
      itemCount: rows.length,
      findChildIndexCallback: (key) => indices[key],
      itemBuilder: (context, index) {
        final row = rows[index];
        return AnimatedBuilder(
          key: row.row.key,
          animation: row.visible && row.from == 1
              ? kAlwaysCompleteAnimation
              : _animation,
          builder: (context, child) {
            final heightFactor = row.visible && row.from == 1
                ? 1.0
                : _rowSize(
                    row,
                    Curves.easeInOutCubic.transform(_animation.value),
                  );
            return ClipRect(
              clipBehavior: heightFactor == 1 ? Clip.none : Clip.hardEdge,
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: heightFactor,
                child: child,
              ),
            );
          },
          child: IgnorePointer(
            ignoring: !row.visible,
            child: ExcludeFocus(
              excluding: !row.visible,
              child: ExcludeSemantics(
                excluding: !row.visible,
                child: SizedBox(width: double.infinity, child: row.row.build()),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }
}
