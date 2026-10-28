enum FeedSourceMode { discovery, all, custom }

class FeedSourceSelection {
  const FeedSourceSelection({
    this.mode = FeedSourceMode.discovery,
    this.sources = const [],
  });

  final FeedSourceMode mode;
  final List<String> sources;

  factory FeedSourceSelection.fromJson(Map<String, dynamic> json) =>
      FeedSourceSelection(
        mode:
            FeedSourceMode.values
                .where((mode) => mode.name == json['mode'])
                .firstOrNull ??
            FeedSourceMode.discovery,
        sources: (json['sources'] as List? ?? const [])
            .whereType<String>()
            .where((source) => source.isNotEmpty)
            .toSet()
            .take(200)
            .toList(),
      );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'sources': sources.toSet().toList(),
  };
}
