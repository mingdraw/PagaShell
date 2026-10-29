enum SidebarSection { services, identities, gateways }

/// 侧边栏的显示偏好，目录空间彼此独立；未设置时根组展开、文件夹折叠。
class SidebarState {
  SidebarState({
    this.visible = true,
    Map<SidebarSection, bool> sections = const {},
    Map<SidebarSection, Set<String>> folders = const {},
  }) : sections = Map.unmodifiable(sections),
       folders = Map.unmodifiable({
         for (final entry in folders.entries)
           entry.key: Set<String>.unmodifiable(entry.value),
       });

  final Map<SidebarSection, bool> sections;
  final Map<SidebarSection, Set<String>> folders;
  final bool visible;

  SidebarState withVisibility(bool visible) =>
      SidebarState(visible: visible, sections: sections, folders: folders);

  bool isSectionExpanded(SidebarSection section) => sections[section] ?? true;

  Set<String> expandedFolders(SidebarSection section) => folders[section] ?? {};

  SidebarState withSection(SidebarSection section, bool expanded) =>
      SidebarState(
        visible: visible,
        sections: {...sections, section: expanded},
        folders: folders,
      );

  SidebarState withFolders(SidebarSection section, Set<String> expanded) =>
      SidebarState(
        visible: visible,
        sections: sections,
        folders: {...folders, section: expanded},
      );
}
