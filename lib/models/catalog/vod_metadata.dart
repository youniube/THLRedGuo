String vodCategory(
  Map<dynamic, dynamic> vod, {
  String fallback = '',
  Map<String, String> categoryNames = const {},
}) {
  for (final value in [
    vod['type_name'],
    vod['vod_category'],
    vod['vod_type'],
    vod['type_id'],
    fallback,
  ]) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) continue;
    final name = categoryNames[text];
    if (name != null && name.isNotEmpty) return name;
    if (!RegExp(r'^\d+$').hasMatch(text) &&
        !{'all', 'hot', '全部', '全部短剧', '精选热门'}.contains(text)) {
      return text;
    }
  }
  return '';
}

List<String> vodTags(Map<dynamic, dynamic> vod) {
  final tags = <String>{};
  for (final raw in [vod['vod_tag'], vod['tags'], vod['vod_class']]) {
    final values = raw is Iterable ? raw : [raw];
    for (final value in values) {
      if (value == null) continue;
      tags.addAll(
        value
            .toString()
            .split(RegExp(r'[,，/|;；]'))
            .map((tag) => tag.trim())
            .where((tag) => tag.isNotEmpty),
      );
    }
  }
  return tags.toList();
}
