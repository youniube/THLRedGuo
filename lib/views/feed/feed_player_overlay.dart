import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import 'package:THLRedLook/utils/theme/app_colors.dart';

class FeedPlayerOverlay extends StatefulWidget {
  const FeedPlayerOverlay({
    super.key,
    required this.title,
    required this.episodeText,
    required this.description,
    required this.playing,
    required this.enabled,
    required this.following,
    required this.danmakuEnabled,
    required this.position,
    required this.duration,
    required this.onTogglePlayback,
    required this.onSeek,
    required this.onFavorite,
    required this.onEpisodes,
    required this.onOpenFull,
    required this.onDanmaku,
    required this.onSettings,
    this.fullscreen = false,
    this.panelOpen = false,
    this.onFullscreen,
  });

  final String title;
  final String episodeText;
  final String description;
  final bool playing;
  final bool enabled;
  final bool following;
  final bool danmakuEnabled;
  final Duration position;
  final Duration duration;
  final VoidCallback onTogglePlayback;
  final ValueChanged<double> onSeek;
  final VoidCallback onFavorite;
  final VoidCallback onEpisodes;
  final VoidCallback? onOpenFull;
  final VoidCallback onDanmaku;
  final VoidCallback onSettings;
  final bool fullscreen;
  final bool panelOpen;
  final VoidCallback? onFullscreen;

  @override
  State<FeedPlayerOverlay> createState() => _FeedPlayerOverlayState();
}

class _FeedPlayerOverlayState extends State<FeedPlayerOverlay> {
  Timer? _hideTimer;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void didUpdateWidget(covariant FeedPlayerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing != oldWidget.playing ||
        widget.enabled != oldWidget.enabled ||
        widget.fullscreen != oldWidget.fullscreen ||
        widget.panelOpen != oldWidget.panelOpen) {
      _visible = true;
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_visible || !widget.enabled || !widget.playing || widget.panelOpen) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && widget.enabled && widget.playing && !widget.panelOpen) {
        setState(() => _visible = false);
      }
    });
  }

  void _show() {
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _tapSurface() {
    if (_visible) widget.onTogglePlayback();
    _show();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  Widget _action(
    String id,
    IconData icon,
    String label,
    VoidCallback? action,
  ) => IconButton(
    key: ValueKey('feed-$id'),
    tooltip: label,
    onPressed: action == null
        ? null
        : () {
            _show();
            action();
          },
    style: IconButton.styleFrom(
      foregroundColor: Colors.white,
      backgroundColor: const Color(0x55000000),
      minimumSize: const Size(48, 48),
    ),
    icon: Icon(icon, size: 27),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxHeight < 480;
      final controlsPadding = EdgeInsets.fromLTRB(16, compact ? 8 : 40, 16, 12);
      final maxActionsHeight =
          (constraints.maxHeight -
                  controlsPadding.vertical -
                  (widget.onFullscreen != null ? 56 : 0))
              .clamp(0.0, double.infinity)
              .toDouble();
      final actions = [
        _action(
          'favorite',
          widget.following ? Icons.bookmark : Icons.bookmark_border,
          widget.following ? '已追剧' : '加入追剧',
          widget.onFavorite,
        ),
        _action(
          'episodes',
          Icons.video_library_outlined,
          '选集',
          widget.onEpisodes,
        ),
        _action(
          'danmaku',
          widget.danmakuEnabled ? Icons.subtitles : Icons.subtitles_off,
          widget.danmakuEnabled ? '关闭弹幕' : '开启弹幕',
          widget.onDanmaku,
        ),
        _action('open-full', Icons.info_outline, '看正片', widget.onOpenFull),
        _action('settings', Icons.tune, '播放设置', widget.onSettings),
      ];
      final progress = widget.duration.inMilliseconds > 0
          ? (widget.position.inMilliseconds / widget.duration.inMilliseconds)
                .clamp(0.0, 1.0)
          : 0.0;
      return Listener(
        onPointerDown: (_) => _hideTimer?.cancel(),
        onPointerUp: (_) => _scheduleHide(),
        onPointerCancel: (_) => _scheduleHide(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              key: const ValueKey('feed-play-surface'),
              behavior: HitTestBehavior.opaque,
              onTap: widget.enabled ? _tapSurface : null,
              child: Center(
                child: !widget.playing && widget.enabled
                    ? const Icon(
                        Icons.play_arrow_rounded,
                        size: 76,
                        color: Colors.white70,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            Positioned.fill(
              child: AnimatedOpacity(
                key: const ValueKey('feed-controls'),
                opacity: _visible ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: IgnorePointer(
                  ignoring: !_visible,
                  child: ExcludeFocus(
                    excluding: !_visible,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // 底部暗色渐变（仅作视觉层次，不拦截任何触控事件）
                        const Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: 260,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Color(0xD9000000),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Padding(
                            padding: controlsPadding,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (widget.onFullscreen != null) ...[
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: _action(
                                      'fullscreen',
                                      widget.fullscreen
                                          ? Icons.fullscreen_exit
                                          : Icons.fullscreen,
                                      widget.fullscreen ? '退出全屏' : '横屏全屏',
                                      widget.onFullscreen,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                ],
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            widget.title,
                                            key: const ValueKey('feed-title'),
                                            maxLines: compact ? 1 : 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 20,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          TextButton.icon(
                                            key: const ValueKey(
                                              'feed-current-episode',
                                            ),
                                            onPressed: () {
                                              _show();
                                              widget.onEpisodes();
                                            },
                                            style: TextButton.styleFrom(
                                              foregroundColor: Colors.white,
                                              padding: EdgeInsets.zero,
                                              alignment: Alignment.centerLeft,
                                            ),
                                            icon: const Icon(
                                              Icons.play_circle_outline,
                                              size: 18,
                                            ),
                                            label: Text(
                                              widget.episodeText,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (!compact &&
                                              widget.description.isNotEmpty)
                                            Text(
                                              widget.description,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 13,
                                                height: 1.45,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxHeight: maxActionsHeight,
                                      ),
                                      child: SingleChildScrollView(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            for (final action in actions)
                                              Padding(
                                                padding: EdgeInsets.only(
                                                  bottom: compact ? 0 : 12,
                                                ),
                                                child: action,
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: _FeedProgress(
                            key: const ValueKey('feed-progress'),
                            value: progress,
                            onSeek:
                                widget.enabled &&
                                    widget.duration > Duration.zero
                                ? widget.onSeek
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _FeedProgress extends StatefulWidget {
  const _FeedProgress({super.key, required this.value, this.onSeek});
  final double value;
  final ValueChanged<double>? onSeek;

  @override
  State<_FeedProgress> createState() => _FeedProgressState();
}

class _FeedProgressState extends State<_FeedProgress> {
  double? _dragging;

  void _updateSeek(double localDx, double totalWidth) {
    if (widget.onSeek == null || totalWidth <= 0) return;
    final progress = (localDx / totalWidth).clamp(0.0, 1.0);
    setState(() => _dragging = progress);
  }

  void _finishSeek() {
    final target = _dragging;
    setState(() => _dragging = null);
    if (target != null && widget.onSeek != null) {
      widget.onSeek!(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveValue = (_dragging ?? widget.value).clamp(0.0, 1.0);
    final isInteractive = widget.onSeek != null;
    final isDragging = _dragging != null;
    final trackHeight = isDragging ? 4.0 : 2.5;

    return Semantics(
      slider: true,
      enabled: isInteractive,
      value: '${(effectiveValue * 100).round()}%',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final progressWidth = width * effectiveValue;

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: isInteractive
                ? (d) => _updateSeek(d.localPosition.dx, width)
                : null,
            onTapUp: isInteractive ? (_) => _finishSeek() : null,
            onTapCancel: isInteractive
                ? () => setState(() => _dragging = null)
                : null,
            onHorizontalDragStart: isInteractive
                ? (d) => _updateSeek(d.localPosition.dx, width)
                : null,
            onHorizontalDragUpdate: isInteractive
                ? (d) => _updateSeek(d.localPosition.dx, width)
                : null,
            onHorizontalDragEnd: isInteractive ? (_) => _finishSeek() : null,
            onHorizontalDragCancel: isInteractive
                ? () => setState(() => _dragging = null)
                : null,
            child: SizedBox(
              height: 20,
              width: width,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  height: trackHeight,
                  width: width,
                  decoration: BoxDecoration(
                    color: AppColors.whiteWithAlpha(0.24),
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // 播放进度渐变单线（左右顶到屏幕边缘）
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          width: progressWidth,
                          height: trackHeight,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [
                                AppColors.hongguoOrange,
                                AppColors.hongguoRed,
                                AppColors.hongguoRedLight,
                              ],
                            ),
                            boxShadow: isDragging
                                ? [
                                    BoxShadow(
                                      color: AppColors.hongguoRedWithAlpha(0.6),
                                      blurRadius: 6,
                                      spreadRadius: 1,
                                    ),
                                  ]
                                : null,
                          ),
                        ),
                      ),
                      // 拖拽手势响应指示微点（静止播放时不显示任何滑块，仅在拖拽微调时给用户清晰反馈）
                      if (isDragging && progressWidth > 0)
                        Positioned(
                          left: (progressWidth - 5).clamp(0.0, width - 10),
                          top: (trackHeight - 10) / 2,
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.white,
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.hongguoRedWithAlpha(0.8),
                                  blurRadius: 6,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

void feedPreviewAction() {}
void feedPreviewSeek(double value) {}

@Preview(name: '推荐视频流 · 手机', size: Size(390, 720))
@Preview(name: '推荐视频流 · 横屏', size: Size(740, 350))
Widget feedPlayerPreview() => MaterialApp(
  theme: ThemeData.dark(),
  home: ColoredBox(
    color: const Color(0xFF172433),
    child: FeedPlayerOverlay(
      title: '合成短剧：山海来信',
      episodeText: '第 3 集 · 共 60 集',
      description: '一封迟来的信，让一段尘封往事重新展开。',
      playing: true,
      enabled: true,
      following: false,
      danmakuEnabled: true,
      position: const Duration(seconds: 26),
      duration: const Duration(minutes: 2),
      onTogglePlayback: feedPreviewAction,
      onSeek: feedPreviewSeek,
      onFavorite: feedPreviewAction,
      onEpisodes: feedPreviewAction,
      onOpenFull: feedPreviewAction,
      onDanmaku: feedPreviewAction,
      onSettings: feedPreviewAction,
    ),
  ),
);
