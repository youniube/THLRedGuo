import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:THLRedLook/core/store/local_store.dart';
import 'package:THLRedLook/core/player/playback_engine.dart';
import 'package:THLRedLook/models/danmaku/danmaku_models.dart';
import 'package:THLRedLook/utils/theme/app_colors.dart';
import 'package:THLRedLook/views/common/widgets.dart';
import 'package:THLRedLook/core/danmaku/external_danmaku_session.dart';
import 'package:THLRedLook/views/player/external_danmaku_controls.dart';
import 'package:THLRedLook/views/player/player_danmaku_sheet_view.dart';

class PlaybackSettingsPage extends StatelessWidget {
  const PlaybackSettingsPage({super.key, required this.store});

  final LocalStore store;

  Future<void> _danmakuSettings(
    BuildContext context,
    DanmakuSettingsTab tab,
  ) async {
    final epoch = store.profileEpoch;
    final session = ExternalDanmakuSession(store);
    try {
      await PlayerDanmakuSheetView.show(
        context: context,
        initialTab: tab,
        style: store.playbackPreferences.danmakuStyle,
        sourceControls: ExternalDanmakuControls(
          session: session,
          showMatching: false,
          showOffset: false,
          onChanged: () {},
        ),
        onStyleChanged: (value) {
          if (store.profileEpoch != epoch) return;
          unawaited(
            saveUserChange(
              context,
              () => store.setPlaybackPreferences(
                store.playbackPreferences.copyWith(danmakuStyle: value),
              ),
            ),
          );
        },
      );
    } finally {
      session.dispose();
    }
  }

  Future<void> _chooseEngine(BuildContext context) async {
    final selected = await showModalBottomSheet<PlaybackEngine>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '播放内核',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              for (final engine in availablePlaybackEngines)
                ListTile(
                  key: ValueKey('settings-engine-${engine.name}'),
                  title: Text(engine.label),
                  subtitle: Text(engine.description),
                  trailing: store.playbackPreferences.engine == engine
                      ? const Icon(
                          Icons.check_rounded,
                          color: AppColors.hongguoRed,
                        )
                      : null,
                  onTap: () => Navigator.pop(context, engine),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && context.mounted) {
      final updated = store.playbackPreferences.copyWith(engine: selected);
      await saveUserChange(
        context,
        () => store.setPlaybackPreferences(updated),
      );
    }
  }

  Future<void> _chooseQuality(BuildContext context) async {
    final qualities = [
      {'label': '自动 · 优先原画', 'value': 0},
      {'label': '1080P · 超清', 'value': 1080},
      {'label': '720P · 高清', 'value': 720},
      {'label': '480P · 标清', 'value': 480},
    ];
    final selected = await showModalBottomSheet<int>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '默认起播画质',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            for (final q in qualities)
              ListTile(
                title: Text(q['label'] as String),
                trailing:
                    store.playbackPreferences.quality == (q['value'] as int)
                    ? const Icon(
                        Icons.check_rounded,
                        color: AppColors.hongguoRed,
                      )
                    : null,
                onTap: () => Navigator.pop(context, q['value'] as int),
              ),
          ],
        ),
      ),
    );
    if (selected != null && context.mounted) {
      final updated = store.playbackPreferences.copyWith(quality: selected);
      await saveUserChange(
        context,
        () => store.setPlaybackPreferences(updated),
      );
    }
  }

  Future<void> _chooseSpeed(BuildContext context) async {
    final speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
    final selected = await showModalBottomSheet<double>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '默认播放倍速',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            for (final s in speeds)
              ListTile(
                title: Text('${s}x${s == 1.0 ? ' (正常速度)' : ''}'),
                trailing: store.playbackPreferences.speed == s
                    ? const Icon(
                        Icons.check_rounded,
                        color: AppColors.hongguoRed,
                      )
                    : null,
                onTap: () => Navigator.pop(context, s),
              ),
          ],
        ),
      ),
    );
    if (selected != null && context.mounted) {
      final updated = store.playbackPreferences.copyWith(speed: selected);
      await saveUserChange(
        context,
        () => store.setPlaybackPreferences(updated),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final prefs = store.playbackPreferences;
        final danmaku = store.externalDanmakuSettings;
        final api = danmaku.endpoints
            .where((source) => source.baseUrl == danmaku.baseUrl)
            .firstOrNull;
        final danmakuSourceSummary = [
          switch (danmaku.mode) {
            'native' => '仅原站',
            'external' => '通用 API',
            _ => '自动选择',
          },
          api?.name ?? '未配置通用 API',
          if (danmaku.endpoints.isNotEmpty) '${danmaku.endpoints.length} 个 API',
        ].join(' · ');
        final style = prefs.danmakuStyle;
        final danmakuDisplaySummary = [
          '字号 ${style.fontSizeScale.toStringAsFixed(2)}x',
          '不透明度 ${(style.opacity * 100).round()}%',
          '区域 ${(style.displayArea * 100).round()}%',
          switch (style.density) {
            DanmakuDensity.low => '低密度',
            DanmakuDensity.medium => '中密度',
            DanmakuDensity.high => '高密度',
          },
        ].join(' · ');
        final danmakuFilterSummary = [
          '${style.keywords.length} 个屏蔽词',
          if (style.blockColored) '屏蔽彩色弹幕',
          '时间偏移在播放时调整',
        ].join(' · ');
        final qualityLabel = switch (prefs.quality) {
          1080 => '1080P 超清',
          720 => '720P 高清',
          480 => '480P 标清',
          _ => '自动（优先原画）',
        };

        return Scaffold(
          appBar: AppBar(title: const Text('播放设置'), centerTitle: true),
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              Text(
                '基础播放偏好',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: AppColors.hongguoRed,
                ),
              ),
              const SizedBox(height: 8),

              Card(
                elevation: 0,
                color: isDark ? AppColors.darkCard : AppColors.greyLight,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    ListTile(
                      key: const ValueKey('settings-engine-entry'),
                      leading: const Icon(Icons.memory_rounded),
                      title: const Text('播放内核'),
                      subtitle: Text(
                        supportsSystemPlaybackEngine
                            ? prefs.engine.label
                            : 'MPV（当前平台固定使用）',
                      ),
                      trailing: supportsSystemPlaybackEngine
                          ? const Icon(Icons.chevron_right_rounded)
                          : null,
                      onTap: supportsSystemPlaybackEngine
                          ? () => _chooseEngine(context)
                          : null,
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.hd_outlined),
                      title: const Text('默认起播画质'),
                      subtitle: Text(qualityLabel),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _chooseQuality(context),
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: const Icon(Icons.speed_rounded),
                      title: const Text('默认播放倍速'),
                      subtitle: Text('${prefs.speed}x'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _chooseSpeed(context),
                    ),
                    if (defaultTargetPlatform == TargetPlatform.android ||
                        defaultTargetPlatform == TargetPlatform.iOS) ...[
                      const Divider(height: 1, indent: 56),
                      SwitchListTile.adaptive(
                        key: const ValueKey('settings-pip-switch'),
                        secondary: const Icon(
                          Icons.picture_in_picture_alt_rounded,
                        ),
                        title: const Text('画中画模式'),
                        subtitle: Text(
                          prefs.pictureInPicture
                              ? '已开启画中画，播放时支持悬浮小窗播放'
                              : '关闭后播放器隐藏画中画入口',
                        ),
                        value: prefs.pictureInPicture,
                        activeThumbColor: AppColors.white,
                        activeTrackColor: AppColors.hongguoRed,
                        onChanged: (val) async {
                          final updated = prefs.copyWith(pictureInPicture: val);
                          await saveUserChange(
                            context,
                            () => store.setPlaybackPreferences(updated),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 20),
              Text(
                '弹幕设置',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: AppColors.hongguoRed,
                ),
              ),
              const SizedBox(height: 8),

              Card(
                elevation: 0,
                color: isDark ? AppColors.darkCard : AppColors.greyLight,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    SwitchListTile.adaptive(
                      key: const ValueKey('settings-danmaku-enabled'),
                      secondary: const Icon(Icons.comment_bank_outlined),
                      title: const Text('弹幕总开关'),
                      subtitle: Text(prefs.danmaku ? '已开启弹幕渲染' : '默认静默不显示弹幕'),
                      value: prefs.danmaku,
                      activeThumbColor: AppColors.white,
                      activeTrackColor: AppColors.hongguoRed,
                      onChanged: (val) async {
                        final updated = prefs.copyWith(danmaku: val);
                        await saveUserChange(
                          context,
                          () => store.setPlaybackPreferences(updated),
                        );
                      },
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      key: const ValueKey('settings-external-danmaku'),
                      leading: const Icon(Icons.subtitles_outlined),
                      title: const Text('弹幕来源与 API'),
                      subtitle: Text(danmakuSourceSummary),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () =>
                          _danmakuSettings(context, DanmakuSettingsTab.sources),
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      key: const ValueKey('settings-danmaku-display'),
                      leading: const Icon(Icons.tune_rounded),
                      title: const Text('弹幕显示设置'),
                      subtitle: Text(danmakuDisplaySummary),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () =>
                          _danmakuSettings(context, DanmakuSettingsTab.display),
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      key: const ValueKey('settings-danmaku-advanced'),
                      leading: const Icon(Icons.filter_alt_outlined),
                      title: const Text('高级与过滤'),
                      subtitle: Text(danmakuFilterSummary),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _danmakuSettings(
                        context,
                        DanmakuSettingsTab.advanced,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
