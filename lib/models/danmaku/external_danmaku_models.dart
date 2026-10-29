import 'dart:convert';

import 'package:THLRedLook/models/catalog/models.dart';

String normalizeDanmakuBase(String value) {
  var base = value.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.endsWith('/api/v2')) base = base.substring(0, base.length - 7);
  if (base.isNotEmpty) {
    final uri = Uri.tryParse(base);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        base.length > 2048) {
      throw const FormatException('请输入完整的 HTTP(S) 弹幕 API 基础地址，可包含服务路径和访问令牌');
    }
  }
  return base;
}

class DanmakuApiSource {
  const DanmakuApiSource({required this.name, required this.baseUrl});
  final String name, baseUrl;
  Map<String, dynamic> toJson() => {'name': name, 'baseUrl': baseUrl};
  factory DanmakuApiSource.fromJson(Map<String, dynamic> value) {
    final name = (value['name'] as String? ?? '').trim();
    final base = normalizeDanmakuBase(value['baseUrl'] as String? ?? '');
    if (name.isEmpty || name.length > 80 || base.isEmpty) {
      throw const FormatException('请填写 API 名称和有效地址');
    }
    return DanmakuApiSource(name: name, baseUrl: base);
  }
}

class ExternalDanmakuSettings {
  const ExternalDanmakuSettings({
    this.baseUrl = '',
    this.mode = 'automatic',
    this.autoMatch = true,
    this.sources = const [],
  });
  final String baseUrl;
  final String mode;
  final bool autoMatch;
  final List<DanmakuApiSource> sources;
  List<DanmakuApiSource> get endpoints => sources.isNotEmpty
      ? sources
      : configured
      ? [DanmakuApiSource(name: '默认 API', baseUrl: baseUrl)]
      : const [];
  bool get configured => baseUrl.isNotEmpty;
  ExternalDanmakuSettings copyWith({
    String? baseUrl,
    String? mode,
    bool? autoMatch,
    List<DanmakuApiSource>? sources,
  }) => ExternalDanmakuSettings(
    baseUrl: baseUrl ?? this.baseUrl,
    mode: mode ?? this.mode,
    autoMatch: autoMatch ?? this.autoMatch,
    sources: List.unmodifiable(sources ?? endpoints),
  );
  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'mode': mode,
    'autoMatch': autoMatch,
    'sources': endpoints.map((value) => value.toJson()).toList(),
  };
  factory ExternalDanmakuSettings.fromJson(Map<String, dynamic> value) {
    var base = normalizeDanmakuBase(value['baseUrl'] as String? ?? '');
    final mode = value['mode'] as String? ?? 'automatic';
    if (!{'automatic', 'native', 'external'}.contains(mode)) {
      throw const FormatException('弹幕来源无效');
    }
    final sources = <DanmakuApiSource>[];
    for (final row
        in (value['sources'] is List ? value['sources'] as List : const [])
            .take(16)) {
      try {
        final source = DanmakuApiSource.fromJson(
          Map<String, dynamic>.from(row as Map),
        );
        if (!sources.any((value) => value.baseUrl == source.baseUrl)) {
          sources.add(source);
        }
      } catch (_) {}
    }
    if (sources.isEmpty && base.isNotEmpty) {
      sources.add(DanmakuApiSource(name: '默认 API', baseUrl: base));
    }
    if (sources.isNotEmpty && !sources.any((value) => value.baseUrl == base)) {
      base = sources.first.baseUrl;
    }
    return ExternalDanmakuSettings(
      baseUrl: base,
      mode: mode,
      autoMatch: value['autoMatch'] is bool ? value['autoMatch'] as bool : true,
      sources: List.unmodifiable(sources),
    );
  }
}

int? danmakuNumber(String value) {
  final number = int.tryParse(value);
  if (number != null) return number > 0 ? number : null;
  const digits = {
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
    '零': 0,
    '〇': 0,
  };
  var total = 0, digit = 0;
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    if (char == '十' || char == '百') {
      total += (digit == 0 ? 1 : digit) * (char == '十' ? 10 : 100);
      digit = 0;
    } else if (digits.containsKey(char)) {
      digit = digits[char]!;
    } else {
      return null;
    }
  }
  return total + digit > 0 ? total + digit : null;
}

int? danmakuSeason(String title) {
  final match = RegExp(
    r'第([\d一二两三四五六七八九十百零〇]+)季|\b(?:season\s*|s)(\d{1,2})(?=\b|e\d)',
    caseSensitive: false,
  ).firstMatch(title);
  return match == null
      ? null
      : danmakuNumber(match.group(1) ?? match.group(2)!);
}

int? danmakuEpisode(String title) {
  final match = RegExp(
    r'第\s*([\d一二两三四五六七八九十百零〇]+)\s*[集话期]|(?:\b(?:ep?\s*|episode\s*)|s\d{1,2}e)(\d+)\b|^(\d+)(?:\s|$)',
    caseSensitive: false,
  ).firstMatch(title);
  return match == null
      ? null
      : danmakuNumber(match.group(1) ?? match.group(2) ?? match.group(3)!);
}

String danmakuTitle(String title) => title
    .toLowerCase()
    .replaceAll(RegExp(r'[（(](?:19|20)\d{2}[)）]'), '')
    .replaceAll(
      RegExp(
        r'[【\[](?:腾讯|爱奇艺|优酷|芒果|哔哩哔哩|bilibili|qq|qiyi|youku|imgo|红果|dandan)[】\]]',
        caseSensitive: false,
      ),
      '',
    )
    .replaceAll(
      RegExp(
        r'第[\d一二两三四五六七八九十百零〇]+季|\b(?:season\s*|s)\d{1,2}\b',
        caseSensitive: false,
      ),
      '',
    )
    .replaceAll(RegExp(r'[\s\-_:：·.,，。!！?？《》「」“”"\x27()（）\[\]【】]+'), '');

String danmakuKind(String value) {
  final lower = value.toLowerCase();
  if ({'movie', '电影', '剧场版'}.contains(lower)) return 'movie';
  if ({'tv', 'tvseries', '电视剧', '短剧', '真人剧'}.contains(lower)) return 'tv';
  if ({
    'anime',
    '动画',
    '动漫',
    '漫剧',
    'tv动画',
    '网络动画',
    'ova',
    'ona',
  }.contains(lower)) {
    return 'anime';
  }
  if ({'variety', '综艺'}.contains(lower)) return 'variety';
  if ({'documentary', '纪录片'}.contains(lower)) return 'documentary';
  return '';
}

class DanmakuMedia {
  const DanmakuMedia({
    required this.workId,
    required this.title,
    this.year = 0,
    this.kind = '',
    this.season,
    this.episode,
    this.episodeKey = '',
  });
  final String workId, title, kind, episodeKey;
  final int year;
  final int? season, episode;
  String get seriesKey => jsonEncode([workId, title, year, kind, season]);
  String get key =>
      jsonEncode([workId, title, year, kind, season, episode, episodeKey]);
  factory DanmakuMedia.from(Drama drama, Episode episode) {
    final raw = episode.raw;
    return DanmakuMedia(
      workId: drama.id,
      title: drama.title,
      year: drama.year,
      kind: danmakuKind(
        drama.mediaType.isNotEmpty ? drama.mediaType : drama.category,
      ),
      season:
          (raw['seasonNumber'] as num?)?.toInt() ??
          (raw['season'] as num?)?.toInt() ??
          danmakuSeason(episode.title) ??
          danmakuSeason(drama.title),
      episode:
          danmakuEpisode(raw['title'] as String? ?? '') ??
          (raw['currentEpisode'] as num?)?.toInt(),
      episodeKey: episode.id.isNotEmpty ? episode.id : episode.title,
    );
  }
}

class DanmakuCandidate {
  const DanmakuCandidate({
    required this.id,
    required this.title,
    this.kind = '',
    this.year = 0,
    this.season,
  });
  final String id, title, kind;
  final int year;
  final int? season;
  factory DanmakuCandidate.fromJson(Map<String, dynamic> row) {
    final title = row['animeTitle']?.toString() ?? '';
    final year =
        RegExp(
          r'(?:19|20)\d{2}',
        ).firstMatch(row['startDate']?.toString() ?? '') ??
        RegExp(r'[（(]((?:19|20)\d{2})[)）]').firstMatch(title);
    return DanmakuCandidate(
      id: row['animeId']?.toString() ?? '',
      title: title,
      kind: danmakuKind(row['typeDescription']?.toString() ?? '').isNotEmpty
          ? danmakuKind(row['typeDescription']?.toString() ?? '')
          : danmakuKind(row['type']?.toString() ?? ''),
      year: int.tryParse(year?.group(year.groupCount == 0 ? 0 : 1) ?? '') ?? 0,
      season: danmakuSeason(title),
    );
  }
  bool matches(DanmakuMedia media) =>
      id.isNotEmpty &&
      danmakuTitle(title) == danmakuTitle(media.title) &&
      (media.year == 0 || media.year == year) &&
      (media.kind.isEmpty || media.kind == kind) &&
      (media.season == season ||
          media.season == 1 && season == null ||
          media.season == null && (season == null || season == 1));
}

class DanmakuLibraryEpisode {
  const DanmakuLibraryEpisode(this.id, this.title);
  final String id, title;
}
