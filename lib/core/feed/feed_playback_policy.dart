import 'dart:math';

import 'package:THLRedLook/models/catalog/models.dart';

enum FeedPlaybackMode { full, randomPreview }

class FeedPreviewSegment {
  const FeedPreviewSegment(this.start, this.end);

  final Duration start;
  final Duration end;
  Duration get duration => end - start;
}

class FeedPlaybackPolicy {
  const FeedPlaybackPolicy({
    this.shortLimit = const Duration(minutes: 10),
    this.longLimit = const Duration(minutes: 15),
    this.previewDuration = const Duration(seconds: 45),
    this.skipOpening = .15,
    this.skipEnding = .25,
  }) : assert(skipOpening >= 0 && skipOpening < 1),
       assert(skipEnding >= 0 && skipEnding < 1),
       assert(skipOpening + skipEnding < 1);

  final Duration shortLimit;
  final Duration longLimit;
  final Duration previewDuration;
  final double skipOpening;
  final double skipEnding;

  FeedPlaybackMode? classify(
    Drama drama, {
    Duration duration = Duration.zero,
    double? aspectRatio,
  }) {
    final category = (drama.rawCategory ?? drama.category).trim().toLowerCase();
    final categoryKind = _categoryMode(category);
    final tagKinds = drama.tags.map((tag) => _categoryMode(tag.toLowerCase()));
    final taggedShort = tagKinds.contains(FeedPlaybackMode.full);
    final taggedLong = tagKinds.contains(FeedPlaybackMode.randomPreview);
    final known =
        categoryKind ??
        (drama.source == 'hongguo'
            ? FeedPlaybackMode.full
            : taggedShort != taggedLong
            ? taggedShort
                  ? FeedPlaybackMode.full
                  : FeedPlaybackMode.randomPreview
            : null);
    if (duration >= longLimit) return FeedPlaybackMode.randomPreview;
    if (known != null) return known;
    if (duration <= Duration.zero) return null;
    if (duration <= shortLimit &&
        aspectRatio != null &&
        aspectRatio.isFinite &&
        aspectRatio > 0 &&
        aspectRatio < 1) {
      return FeedPlaybackMode.full;
    }
    return FeedPlaybackMode.randomPreview;
  }

  FeedPlaybackMode? _categoryMode(String value) {
    if (value.isEmpty) return null;
    if (const [
      '短剧',
      '微剧',
      '漫剧',
      'short_play',
      'shortplay',
      'short_drama',
      'playlet',
      'motion_comic',
      'comic-drama',
      'comic_series',
      'real-drama',
      'real_series',
      'ai-drama',
      'ai_series',
    ].any(value.contains)) {
      return FeedPlaybackMode.full;
    }
    if (const [
      '电影',
      '电视剧',
      '连续剧',
      '网剧',
      '综艺',
      '纪录',
      '动漫',
      '动画',
      '剧场版',
      'movie',
      'film',
      'tv_series',
      'documentary',
      'anime',
      'animation',
      'variety',
    ].any(value.contains)) {
      return FeedPlaybackMode.randomPreview;
    }
    return null;
  }

  FeedPreviewSegment segment(Duration duration, Random random) {
    if (duration.inMilliseconds <= 0) {
      throw ArgumentError.value(duration, 'duration');
    }
    final total = duration.inMilliseconds;
    final first = (total * skipOpening).floor();
    final last = (total * (1 - skipEnding)).floor().clamp(first + 1, total);
    final length = min(previewDuration.inMilliseconds, last - first);
    final choices = last - first - length;
    final start = first + (choices > 0 ? random.nextInt(choices + 1) : 0);
    return FeedPreviewSegment(
      Duration(milliseconds: start),
      Duration(milliseconds: start + length),
    );
  }
}

class FeedPlaybackPlan {
  FeedPlaybackPlan({
    required this.drama,
    required this.resumeIndex,
    required this.resumePosition,
    required int episodeCount,
    this.policy = const FeedPlaybackPolicy(),
    Random? random,
  }) : assert(episodeCount > 0),
       _random = random ?? Random() {
    previewIndex = _random.nextInt(episodeCount);
    mode = policy.classify(drama);
  }

  final Drama drama;
  int resumeIndex;
  double resumePosition;
  final FeedPlaybackPolicy policy;
  final Random _random;
  late final int previewIndex;
  FeedPlaybackMode? mode;
  FeedPreviewSegment? preview;
  int? previewEpisode;
  bool finished = false;
  bool _resolved = false;

  int get initialIndex => mode == FeedPlaybackMode.randomPreview
      ? previewEpisode ?? previewIndex
      : resumeIndex;
  double get initialPosition =>
      mode == FeedPlaybackMode.randomPreview ? 0 : resumePosition;

  FeedPlaybackMode resolve(Duration duration, double? aspectRatio) {
    if (_resolved) {
      if (mode == FeedPlaybackMode.full && duration >= policy.longLimit) {
        mode = FeedPlaybackMode.randomPreview;
      }
      return mode!;
    }
    final decision = policy.classify(
      drama,
      duration: duration,
      aspectRatio: aspectRatio,
    );
    if (decision != null) {
      mode = decision;
      final reliableType = policy.classify(drama) != null;
      final reliableAspect =
          aspectRatio != null && aspectRatio.isFinite && aspectRatio > 0;
      _resolved = duration > Duration.zero && (reliableType || reliableAspect);
    }
    return decision ?? FeedPlaybackMode.randomPreview;
  }

  FeedPreviewSegment previewFor(int index, Duration duration) {
    if (preview == null || previewEpisode != index || preview!.end > duration) {
      preview = policy.segment(duration, _random);
      previewEpisode = index;
    }
    return preview!;
  }
}
