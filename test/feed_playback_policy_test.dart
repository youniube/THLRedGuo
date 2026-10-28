import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:THLRedLook/core/bridge/core_bridge.dart';
import 'package:THLRedLook/core/feed/feed_playback_policy.dart';
import 'package:THLRedLook/core/feed/video_feed_controller.dart';
import 'package:THLRedLook/core/store/local_store.dart';
import 'package:THLRedLook/models/catalog/models.dart';
import 'package:THLRedLook/models/catalog/vod_metadata.dart';

Drama sample({
  String category = '',
  List<String> tags = const [],
  String source = 'synthetic',
}) => Drama(
  id: '$source:sample',
  source: source,
  title: '合成内容',
  category: category,
  tags: tags,
);

class _Repository extends AppRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  const policy = FeedPlaybackPolicy();

  test('未知分类保持未知，数字分类只有取得名称后才参与识别', () {
    expect(vodCategory({}), '');
    expect(dramaCategoryLabel(''), '未分类');
    expect(vodCategory({'type_id': '2'}), '');
    expect(vodCategory({'type_id': '2'}, categoryNames: {'2': '电视剧'}), '电视剧');
    expect(vodCategory({'vod_category': '', 'type_name': '电影'}), '电影');
    expect(vodCategory({}, fallback: 'hot'), '');
    expect(policy.classify(sample()), isNull);
    final displayFallback = Drama.fromJson({
      'id': 'synthetic:fallback',
      'source': 'synthetic',
      'category': 'app:unknown',
    });
    expect(displayFallback.category, '短剧');
    expect(displayFallback.rawCategory, 'app:unknown');
    expect(policy.classify(displayFallback), isNull);
    expect(Drama.fromJson(displayFallback.toJson()).rawCategory, 'app:unknown');
    expect(
      Drama.fromJson({'id': 'synthetic:empty', 'source': 'synthetic'}).category,
      '',
    );
  });

  test('标签合并去重，保留类型与题材信息', () {
    expect(
      vodTags({
        'vod_tag': '电影,爱情',
        'tags': ['爱情', '悬疑'],
        'vod_class': '剧情/喜剧',
      }),
      ['电影', '爱情', '悬疑', '剧情', '喜剧'],
    );
    expect(policy.classify(sample(tags: ['都市', '爱情'])), isNull);
  });

  test('可靠类型优先于画幅与题材标签', () {
    for (final category in ['短剧', '微短剧', '漫剧', 'app:discover:playlet']) {
      expect(
        policy.classify(
          sample(category: category),
          duration: const Duration(minutes: 3),
          aspectRatio: 1.8,
        ),
        FeedPlaybackMode.full,
      );
    }
    for (final category in ['电影', '电视剧', '网剧', '综艺', '纪录片', '动漫', '动画']) {
      expect(
        policy.classify(
          sample(category: category, tags: ['短剧']),
          duration: const Duration(minutes: 2),
          aspectRatio: .56,
        ),
        FeedPlaybackMode.randomPreview,
      );
    }
    expect(policy.classify(sample(source: 'hongguo')), FeedPlaybackMode.full);
  });

  test('未知内容覆盖阈值、画幅缺失和中间区间', () {
    expect(
      policy.classify(
        sample(),
        duration: const Duration(minutes: 10),
        aspectRatio: .56,
      ),
      FeedPlaybackMode.full,
    );
    expect(
      policy.classify(
        sample(),
        duration: const Duration(minutes: 12),
        aspectRatio: .56,
      ),
      FeedPlaybackMode.randomPreview,
    );
    expect(
      policy.classify(
        sample(),
        duration: const Duration(minutes: 15),
        aspectRatio: .56,
      ),
      FeedPlaybackMode.randomPreview,
    );
    expect(
      policy.classify(
        sample(),
        duration: const Duration(minutes: 2),
        aspectRatio: 1.8,
      ),
      FeedPlaybackMode.randomPreview,
    );
    expect(
      policy.classify(sample(), duration: const Duration(minutes: 2)),
      FeedPlaybackMode.randomPreview,
    );
    expect(
      policy.classify(
        sample(category: '短剧合集'),
        duration: const Duration(hours: 2),
      ),
      FeedPlaybackMode.randomPreview,
    );
    expect(
      policy.classify(
        sample(category: '电影'),
        duration: const Duration(hours: 2),
        override: FeedPlaybackMode.full,
      ),
      FeedPlaybackMode.full,
    );
  });

  test('随机区间包含完整片段，并避开约定的开头和结尾', () {
    for (final seconds in [2, 60, 90, 600, 2700, 7200]) {
      final duration = Duration(seconds: seconds);
      for (var seed = 0; seed < 50; seed++) {
        final segment = policy.segment(duration, Random(seed));
        expect(
          segment.start.inMilliseconds,
          greaterThanOrEqualTo((duration.inMilliseconds * .15).floor()),
        );
        expect(
          segment.end.inMilliseconds,
          lessThanOrEqualTo((duration.inMilliseconds * .75).floor()),
        );
        expect(segment.duration, greaterThan(Duration.zero));
        expect(
          segment.duration,
          lessThanOrEqualTo(const Duration(seconds: 45)),
        );
      }
    }
    expect(() => policy.segment(Duration.zero, Random(1)), throwsArgumentError);
  });

  test('同集重试沿用片段，换集或片长缩短才重新计算', () {
    final plan = FeedPlaybackPlan(
      drama: sample(category: '电视剧'),
      resumeIndex: 2,
      resumePosition: 360,
      episodeCount: 8,
      random: Random(2),
    );
    expect(plan.initialPosition, 0);
    expect(plan.initialIndex, inInclusiveRange(0, 7));
    final segment = plan.previewFor(3, const Duration(minutes: 45));
    expect(
      identical(plan.previewFor(3, const Duration(minutes: 45)), segment),
      true,
    );
    expect(
      identical(plan.previewFor(4, const Duration(minutes: 45)), segment),
      false,
    );
    expect(
      plan.previewFor(4, const Duration(minutes: 1)).end,
      lessThan(const Duration(minutes: 1)),
    );
  });

  test('元数据判定后保持作品策略，切线路不因画幅变化重新随机', () {
    final plan = FeedPlaybackPlan(
      drama: sample(),
      resumeIndex: 0,
      resumePosition: 0,
      episodeCount: 3,
    );
    expect(
      plan.resolve(const Duration(seconds: 90), .56),
      FeedPlaybackMode.full,
    );
    expect(
      plan.resolve(const Duration(seconds: 90), 1.8),
      FeedPlaybackMode.full,
    );
    expect(
      plan.resolve(const Duration(minutes: 45), 1.8),
      FeedPlaybackMode.randomPreview,
    );
    final segment = plan.previewFor(2, const Duration(minutes: 45));
    expect(plan.initialIndex, 2);
    expect(
      plan.resolve(const Duration(minutes: 45), .56),
      FeedPlaybackMode.randomPreview,
    );
    expect(
      identical(plan.previewFor(2, const Duration(minutes: 45)), segment),
      true,
    );
  });

  test('片长检测失败不锁定未知作品的判断，重试可重新识别短剧', () {
    final plan = FeedPlaybackPlan(
      drama: sample(),
      resumeIndex: 0,
      resumePosition: 0,
      episodeCount: 1,
    );
    expect(plan.resolve(Duration.zero, null), FeedPlaybackMode.randomPreview);
    expect(plan.mode, isNull);
    expect(
      plan.resolve(const Duration(seconds: 90), .56),
      FeedPlaybackMode.full,
    );
  });

  test('作品修正优先于站源规则，恢复自动后保留站源规则并可重新加载', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = LocalStore(preferences);
    final feed = VideoFeedController(_Repository(), store);
    final drama = sample(source: 'hongguo');
    final detail = DramaDetail(drama, [
      Episode({'id': 'episode'}, 1),
    ]);
    try {
      await store.setFeedPlaybackRule(
        'source:hongguo',
        FeedPlaybackMode.randomPreview.name,
      );
      expect(feed.playbackFor(detail).mode, FeedPlaybackMode.randomPreview);
      await store.setFeedPlaybackRule(
        'drama:${drama.id}',
        FeedPlaybackMode.full.name,
      );
      expect(feed.playbackFor(detail).mode, FeedPlaybackMode.full);
      await store.setFeedPlaybackRule('drama:${drama.id}', null);
      expect(feed.playbackFor(detail).mode, FeedPlaybackMode.randomPreview);
      final reloaded = LocalStore(preferences);
      expect(reloaded.feedPlaybackRules, {'source:hongguo': 'randomPreview'});
      reloaded.dispose();
    } finally {
      feed.dispose();
      store.dispose();
    }
  });
}
