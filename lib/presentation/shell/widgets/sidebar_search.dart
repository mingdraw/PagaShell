part of 'sidebar.dart';

typedef _SearchDisplay = ({List<String> terms, String detail, bool selected});

typedef _SidebarSearchHit = ({
  SidebarSection section,
  int slot,
  String detail,
  Host? host,
  Identity? identity,
});

List<String> _searchTerms(String query) => query
    .trim()
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .where((s) => s.isNotEmpty)
    .toSet()
    .toList();

List<_SidebarSearchHit> _searchSidebar(List<String> terms) {
  if (terms.isEmpty) return const [];
  final hits = <_SidebarSearchHit>[];
  var slot = -1;
  SidebarSection? previous;

  void add(
    SidebarSection section,
    String detail, {
    Host? host,
    Identity? identity,
  }) {
    if (previous != section) slot++;
    previous = section;
    hits.add((
      section: section,
      slot: ++slot,
      detail: detail,
      host: host,
      identity: identity,
    ));
  }

  String directory(Map<String, Folder> folders, String? parentId) {
    final parts = <String>[];
    final visited = <String>{};
    while (parentId != null && visited.add(parentId)) {
      final folder = folders[parentId];
      if (folder == null) break;
      parts.add(folder.name);
      parentId = folder.parentId;
    }
    return parts.reversed.join(' / ');
  }

  bool matches(String value) => terms.every(value.toLowerCase().contains);

  final gateways = Get.isRegistered<GatewayController>()
      ? Get.find<GatewayController>().sorted
      : const <Host>[];
  final gatewayNames = {
    for (final gateway in gateways) gateway.id: gateway.name,
  };

  void matchHosts(
    List<Host> hosts,
    List<Folder> allFolders,
    SidebarSection section,
  ) {
    final folders = {for (final folder in allFolders) folder.id: folder};
    for (final host in hosts) {
      final path = directory(folders, host.folderId);
      final via = gatewayNames[host.gatewayId];
      final detail = [
        if (path.isNotEmpty) path,
        host.address,
        if (via != null) '经由 @gateway'.trParams({'gateway': via}),
        if (host.tags.isNotEmpty) host.tags.join(', '),
        if (host.note.isNotEmpty) host.note,
      ].join(' · ');
      if (matches(
        '${host.searchText} ${host.port} $detail ${host.serviceType.label} ${host.gatewayType.label}',
      )) {
        add(section, detail, host: host);
      }
    }
  }

  matchHosts(
    Get.find<HostController>().sorted,
    Get.find<FolderController>().folders,
    SidebarSection.services,
  );
  final folders = {
    for (final folder in Get.find<IdentityFolderController>().folders)
      folder.id: folder,
  };
  final identities = Get.find<IdentityController>().identities.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  for (final identity in identities) {
    final path = directory(folders, identity.folderId);
    final detail = [
      if (path.isNotEmpty) path,
      if (identity.username.isNotEmpty) identity.username,
      identity.serviceType.label,
    ].join(' · ');
    if (matches('${identity.name} $detail')) {
      add(SidebarSection.identities, detail, identity: identity);
    }
  }
  if (gateways.isNotEmpty) {
    matchHosts(
      gateways,
      Get.find<GatewayFolderController>().folders,
      SidebarSection.gateways,
    );
  }
  return hits;
}

Widget _sidebarMatchText(String text, List<String> terms, TextStyle style) {
  if (terms.isEmpty) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
  final pattern = RegExp(
    (terms.toList()..sort((a, b) => b.length.compareTo(a.length)))
        .map(RegExp.escape)
        .join('|'),
    caseSensitive: false,
  );
  final spans = <InlineSpan>[];
  var start = 0;
  for (final match in pattern.allMatches(text)) {
    if (start < match.start) {
      spans.add(TextSpan(text: text.substring(start, match.start)));
    }
    spans.add(
      TextSpan(
        text: match[0],
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
    start = match.end;
  }
  if (spans.isEmpty) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
  if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
  return Text.rich(
    TextSpan(children: spans),
    style: style,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}

Widget? _searchSubtitle(BuildContext context, _SearchDisplay? search) =>
    search == null
    ? null
    : _sidebarMatchText(
        search.detail,
        search.terms,
        TextStyle(
          fontSize: 11,
          color: shadcn.Theme.of(context).colorScheme.mutedForeground,
        ),
      );
