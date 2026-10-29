const danmakuWindowMs = 30000;
const danmakuLifetimeMs = 8000;
const danmakuMaxDurationMs = 86400000;

enum DanmakuMode { scroll, top, bottom }

enum DanmakuDensity { low, medium, high }

DanmakuMode parseDanmakuMode(Object? value) => switch (value?.toString()) {
  'top' || '5' => DanmakuMode.top,
  'bottom' || '4' => DanmakuMode.bottom,
  _ => DanmakuMode.scroll,
};

int parseDanmakuColor(Object? value) {
  if (value is num && value.isFinite) return value.toInt().clamp(0, 0xffffff);
  final text = value?.toString() ?? '';
  final parsed = text.startsWith('#')
      ? int.tryParse(text.substring(1), radix: 16)
      : int.tryParse(text) ?? int.tryParse(text, radix: 16);
  return parsed?.clamp(0, 0xffffff) ?? 0xffffff;
}

class DanmakuItem {
  const DanmakuItem({
    required this.id,
    required this.text,
    required this.timeMs,
    this.color = 0xffffff,
    this.mode = DanmakuMode.scroll,
  });
  final String id;
  final String text;
  final int timeMs;
  final int color;
  final DanmakuMode mode;
}

class DanmakuPage {
  const DanmakuPage({
    required this.episodeId,
    required this.startMs,
    required this.nextMs,
    required this.items,
  });
  final String episodeId;
  final int startMs;
  final int nextMs;
  final List<DanmakuItem> items;

  factory DanmakuPage.fromJson(
    Map<String, dynamic> json, {
    required String episodeId,
    required int startMs,
    required int durationMs,
  }) {
    final next = json['nextMs'];
    final rows = json['items'];
    if (json['episodeId'] != episodeId ||
        json['startMs'] != startMs ||
        next is! int ||
        next <= startMs ||
        next > durationMs ||
        rows is! List) {
      throw const FormatException('弹幕分集或时间范围不符');
    }
    final items = <DanmakuItem>[];
    final seen = <String>{};
    for (final row in rows.take(90)) {
      if (row is! Map) continue;
      final id = row['id'], text = row['text'], time = row['timeMs'];
      if (id is! String ||
          id.isEmpty ||
          id.length > 120 ||
          text is! String ||
          time is! int ||
          time < startMs ||
          time >= next ||
          seen.contains(id)) {
        continue;
      }
      final cleaned = text
          .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]'), ' ')
          .trim();
      if (cleaned.isEmpty) continue;
      seen.add(id);
      items.add(
        DanmakuItem(
          id: id,
          text: String.fromCharCodes(cleaned.runes.take(181)),
          timeMs: time,
          color: parseDanmakuColor(row['color']),
          mode: parseDanmakuMode(row['mode']),
        ),
      );
    }
    items.sort((a, b) => a.timeMs.compareTo(b.timeMs));
    return DanmakuPage(
      episodeId: episodeId,
      startMs: startMs,
      nextMs: next,
      items: List.unmodifiable(items),
    );
  }
}

class DanmakuStyle {
  const DanmakuStyle({
    this.fontSizeScale = 1.0,
    this.opacity = 1.0,
    this.displayArea = 0.5,
    this.useOriginalColor = true,
    this.color = 0xffffff,
    this.outline = false,
    this.shadow = true,
    this.density = DanmakuDensity.medium,
    this.speed = 1,
    this.scroll = true,
    this.top = true,
    this.bottom = true,
    this.subtitleSafe = true,
    this.keywords = const [],
    this.blockColored = false,
  });

  final double fontSizeScale;
  final double opacity;
  final double displayArea;
  final bool useOriginalColor, outline, shadow, scroll, top, bottom;
  final bool subtitleSafe, blockColored;
  final int color;
  final DanmakuDensity density;
  final double speed;
  final List<String> keywords;

  bool accepts(DanmakuItem item) {
    if (blockColored && item.color != 0xffffff) return false;
    if (!(switch (item.mode) {
      DanmakuMode.scroll => scroll,
      DanmakuMode.top => top,
      DanmakuMode.bottom => bottom,
    })) {
      return false;
    }
    final text = item.text.toLowerCase();
    return !keywords.any(
      (word) => word.isNotEmpty && text.contains(word.toLowerCase()),
    );
  }

  int colorFor(DanmakuItem item) => useOriginalColor ? item.color : color;

  DanmakuStyle copyWith({
    double? fontSizeScale,
    double? opacity,
    double? displayArea,
    bool? useOriginalColor,
    int? color,
    bool? outline,
    bool? shadow,
    DanmakuDensity? density,
    double? speed,
    bool? scroll,
    bool? top,
    bool? bottom,
    bool? subtitleSafe,
    List<String>? keywords,
    bool? blockColored,
  }) => DanmakuStyle(
    fontSizeScale: fontSizeScale ?? this.fontSizeScale,
    opacity: opacity ?? this.opacity,
    displayArea: displayArea ?? this.displayArea,
    useOriginalColor: useOriginalColor ?? this.useOriginalColor,
    color: color ?? this.color,
    outline: outline ?? this.outline,
    shadow: shadow ?? this.shadow,
    density: density ?? this.density,
    speed: speed ?? this.speed,
    scroll: scroll ?? this.scroll,
    top: top ?? this.top,
    bottom: bottom ?? this.bottom,
    subtitleSafe: subtitleSafe ?? this.subtitleSafe,
    keywords: keywords == null ? this.keywords : List.unmodifiable(keywords),
    blockColored: blockColored ?? this.blockColored,
  );

  Map<String, dynamic> toJson() => {
    'fontSizeScale': fontSizeScale,
    'opacity': opacity,
    'displayArea': displayArea,
    'useOriginalColor': useOriginalColor,
    'color': color,
    'outline': outline,
    'shadow': shadow,
    'density': density.name,
    'speed': speed,
    'scroll': scroll,
    'top': top,
    'bottom': bottom,
    'subtitleSafe': subtitleSafe,
    'keywords': keywords,
    'blockColored': blockColored,
  };

  factory DanmakuStyle.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const DanmakuStyle();
    double bounded(String key, double fallback, double min, double max) {
      final value = json[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    bool flag(String key, bool fallback) =>
        json[key] is bool ? json[key] as bool : fallback;
    final words = json['keywords'];
    return DanmakuStyle(
      fontSizeScale: bounded('fontSizeScale', 1, .6, 2),
      opacity: bounded('opacity', 1, .1, 1),
      displayArea: bounded('displayArea', .5, .2, 1),
      useOriginalColor: flag('useOriginalColor', true),
      color: parseDanmakuColor(json['color']),
      outline: flag('outline', false),
      shadow: flag('shadow', true),
      density:
          DanmakuDensity.values
              .where((value) => value.name == json['density'])
              .firstOrNull ??
          DanmakuDensity.medium,
      speed: bounded('speed', 1, .5, 2),
      scroll: flag('scroll', true),
      top: flag('top', true),
      bottom: flag('bottom', true),
      subtitleSafe: flag('subtitleSafe', true),
      keywords: List.unmodifiable(
        (words is List ? words : const [])
            .whereType<String>()
            .map((word) => String.fromCharCodes(word.trim().runes.take(60)))
            .where((word) => word.isNotEmpty)
            .toSet()
            .take(100),
      ),
      blockColored: flag('blockColored', false),
    );
  }
}
