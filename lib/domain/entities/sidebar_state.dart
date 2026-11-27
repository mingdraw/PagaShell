enum SidebarSection { services, identities, gateways }

/// 侧边栏的显示偏好，目录空间彼此独立；未设置时根组展开、文件夹折叠。
class SidebarState {
  static const int maxRecentHosts = 8;
  static const double defaultWidth = 264;
  static const double minWidth = 200;
  static const double maxWidth = 420;

  /// 终端字号（单位：pt）。
  static const double defaultTerminalFontSize = 13;
  static const double minTerminalFontSize = 8;
  static const double maxTerminalFontSize = 24;

  SidebarState({
    this.visible = true,
    double width = defaultWidth,
    double terminalFontSize = defaultTerminalFontSize,
    Map<SidebarSection, bool> sections = const {},
    Map<SidebarSection, Set<String>> folders = const {},
    List<String> recentHostIds = const [],
  }) : width = width.clamp(minWidth, maxWidth),
       terminalFontSize = terminalFontSize.clamp(
         minTerminalFontSize,
         maxTerminalFontSize,
       ),
       sections = Map.unmodifiable(sections),
       folders = Map.unmodifiable({
         for (final entry in folders.entries)
           entry.key: Set<String>.unmodifiable(entry.value),
       }),
       recentHostIds = List.unmodifiable(recentHostIds);

  final Map<SidebarSection, bool> sections;
  final Map<SidebarSection, Set<String>> folders;
  final List<String> recentHostIds;
  final bool visible;
  final double width;
  final double terminalFontSize;

  SidebarState withVisibility(bool visible) => SidebarState(
    visible: visible,
    width: width,
    terminalFontSize: terminalFontSize,
    sections: sections,
    folders: folders,
    recentHostIds: recentHostIds,
  );

  SidebarState withWidth(double width) => SidebarState(
    visible: visible,
    width: width,
    terminalFontSize: terminalFontSize,
    sections: sections,
    folders: folders,
    recentHostIds: recentHostIds,
  );

  SidebarState withTerminalFontSize(double fontSize) => SidebarState(
    visible: visible,
    width: width,
    terminalFontSize: fontSize,
    sections: sections,
    folders: folders,
    recentHostIds: recentHostIds,
  );

  bool isSectionExpanded(SidebarSection section) => sections[section] ?? true;

  Set<String> expandedFolders(SidebarSection section) => folders[section] ?? {};

  SidebarState withSection(SidebarSection section, bool expanded) =>
      SidebarState(
        visible: visible,
        width: width,
        terminalFontSize: terminalFontSize,
        sections: {...sections, section: expanded},
        folders: folders,
        recentHostIds: recentHostIds,
      );

  SidebarState withFolders(SidebarSection section, Set<String> expanded) =>
      SidebarState(
        visible: visible,
        width: width,
        terminalFontSize: terminalFontSize,
        sections: sections,
        folders: {...folders, section: expanded},
        recentHostIds: recentHostIds,
      );

  SidebarState withRecentHost(String hostId) {
    final next = [
      hostId,
      for (final id in recentHostIds)
        if (id != hostId) id,
    ];
    if (next.length > maxRecentHosts) {
      next.removeRange(maxRecentHosts, next.length);
    }
    return SidebarState(
      visible: visible,
      width: width,
      terminalFontSize: terminalFontSize,
      sections: sections,
      folders: folders,
      recentHostIds: next,
    );
  }
}
