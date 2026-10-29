import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:THLRedLook/models/danmaku/danmaku_models.dart';
import 'package:THLRedLook/utils/theme/app_colors.dart';
import 'package:THLRedLook/views/danmaku/danmaku_overlay.dart';

enum DanmakuSettingsTab { sources, display, advanced }

class PlayerDanmakuSheetView extends StatefulWidget {
  const PlayerDanmakuSheetView({
    super.key,
    required this.style,
    required this.onStyleChanged,
    this.sourceControls,
    this.timingControls,
    this.initialTab = DanmakuSettingsTab.display,
  });
  final DanmakuStyle style;
  final ValueChanged<DanmakuStyle> onStyleChanged;
  final Widget? sourceControls, timingControls;
  final DanmakuSettingsTab initialTab;
  static Future<void> show({
    required BuildContext context,
    required DanmakuStyle style,
    required ValueChanged<DanmakuStyle> onStyleChanged,
    Widget? sourceControls,
    Widget? timingControls,
  }) => showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: true,
    builder: (_) => PlayerDanmakuSheetView(
      style: style,
      onStyleChanged: onStyleChanged,
      sourceControls: sourceControls,
      timingControls: timingControls,
    ),
  );
  @override
  State<PlayerDanmakuSheetView> createState() => _PlayerDanmakuSheetViewState();
}

class _PlayerDanmakuSheetViewState extends State<PlayerDanmakuSheetView> {
  late DanmakuStyle _style = widget.style;
  void _update(DanmakuStyle next) {
    setState(() => _style = next);
    widget.onStyleChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Theme(
      data: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.hongguoRed,
          brightness: Brightness.dark,
        ),
      ),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 620),
          decoration: const BoxDecoration(
            color: AppColors.darkSurface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: math.min(
                760,
                (size.height - MediaQuery.paddingOf(context).vertical) * .92,
              ),
              child: DefaultTabController(
                length: 3,
                initialIndex: widget.initialTab.index,
                child: FocusTraversalGroup(
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 6, 8, 0),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.subtitles_rounded,
                              color: AppColors.hongguoRed,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                '弹幕设置',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '关闭',
                              onPressed: () => Navigator.maybePop(context),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                      ),
                      const TabBar(
                        tabs: [
                          Tab(text: '数据源'),
                          Tab(text: '显示'),
                          Tab(text: '高级'),
                        ],
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            _list([
                              widget.sourceControls ??
                                  const Text('播放视频时可配置弹幕来源与匹配。'),
                            ]),
                            _display(),
                            _advanced(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _list(List<Widget> children) => Material(
    type: MaterialType.transparency,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: children,
    ),
  );
  Widget _caption(String text) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 10),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white70,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
  Widget _choices<T>(
    List<T> values,
    T selected,
    String Function(T) label,
    void Function(T) change, {
    String? keyPrefix,
  }) => Wrap(
    spacing: 8,
    runSpacing: 6,
    children: [
      for (final value in values)
        ChoiceChip(
          key: keyPrefix == null ? null : ValueKey('$keyPrefix-$value'),
          label: Text(label(value)),
          selected: value == selected,
          onSelected: (_) => change(value),
        ),
    ],
  );
  Widget _slider(
    String label,
    String valueLabel,
    double value,
    double min,
    double max,
    int divisions,
    ValueChanged<double> change,
    String key,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text(valueLabel, style: const TextStyle(color: AppColors.hongguoRed)),
        ],
      ),
      Slider(
        key: ValueKey(key),
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        label: valueLabel,
        onChanged: change,
      ),
    ],
  );
  Widget _display() => KeyedSubtree(
    key: const ValueKey('danmaku-display-list'),
    child: _list([
      Container(
        height: 64,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black45,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '这是一条弹幕效果预览 🚀',
          key: const ValueKey('danmaku-preview'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: danmakuTextStyle(
            _style,
            16 * _style.fontSizeScale,
            itemColor: 0xa5e8ff,
          ),
        ),
      ),
      const SizedBox(height: 16),
      _slider(
        '字体大小',
        '${_style.fontSizeScale.toStringAsFixed(2)}x',
        _style.fontSizeScale,
        .6,
        2,
        28,
        (value) => _update(_style.copyWith(fontSizeScale: value)),
        'danmaku-font-slider',
      ),
      _choices(
        [.8, 1.0, 1.25, 1.5],
        _style.fontSizeScale,
        (value) => switch (value) {
          .8 => '小',
          1.0 => '标准',
          1.25 => '大',
          _ => '特大',
        },
        (value) => _update(_style.copyWith(fontSizeScale: value)),
        keyPrefix: 'danmaku-size',
      ),
      const SizedBox(height: 16),
      _slider(
        '不透明度',
        '${(_style.opacity * 100).round()}%',
        _style.opacity,
        .1,
        1,
        18,
        (value) => _update(_style.copyWith(opacity: value)),
        'danmaku-opacity-slider',
      ),
      _choices(
        [.4, .6, .8, 1.0],
        _style.opacity,
        (value) => '${(value * 100).round()}%',
        (value) => _update(_style.copyWith(opacity: value)),
        keyPrefix: 'danmaku-opacity',
      ),
      _caption('文字颜色'),
      _choices(
        [true, false],
        _style.useOriginalColor,
        (value) => value ? 'API 原色' : '统一颜色',
        (value) => _update(_style.copyWith(useOriginalColor: value)),
      ),
      if (!_style.useOriginalColor) ...[
        const SizedBox(height: 8),
        _choices(
          [0xffffff, 0xffe6a7, 0xa5e8ff, 0xc7f4c2, 0xffc8dd],
          _style.color,
          (value) => switch (value) {
            0xffe6a7 => '柔黄',
            0xa5e8ff => '浅蓝',
            0xc7f4c2 => '薄荷',
            0xffc8dd => '浅粉',
            _ => '白色',
          },
          (value) => _update(_style.copyWith(color: value)),
        ),
      ],
      SwitchListTile.adaptive(
        key: const ValueKey('danmaku-outline'),
        contentPadding: EdgeInsets.zero,
        title: const Text('细描边'),
        value: _style.outline,
        onChanged: (value) => _update(_style.copyWith(outline: value)),
      ),
      SwitchListTile.adaptive(
        key: const ValueKey('danmaku-shadow'),
        contentPadding: EdgeInsets.zero,
        title: const Text('柔和阴影'),
        value: _style.shadow,
        onChanged: (value) => _update(_style.copyWith(shadow: value)),
      ),
      _caption('滚动与顶部弹幕区域'),
      _choices(
        [.25, .4, .5, .75, 1.0],
        _style.displayArea,
        (value) => value == 1 ? '全屏' : '${(value * 100).round()}%',
        (value) => _update(_style.copyWith(displayArea: value)),
        keyPrefix: 'danmaku-area',
      ),
      _caption('弹幕密度'),
      _choices(
        DanmakuDensity.values,
        _style.density,
        (value) => switch (value) {
          DanmakuDensity.low => '低 · 舒适',
          DanmakuDensity.medium => '中 · 均衡',
          DanmakuDensity.high => '高 · 热闹',
        },
        (value) => _update(_style.copyWith(density: value)),
      ),
      const SizedBox(height: 20),
      _slider(
        '滚动速度',
        '${_style.speed.toStringAsFixed(1)}x',
        _style.speed,
        .5,
        2,
        15,
        (value) => _update(_style.copyWith(speed: value)),
        'danmaku-speed-slider',
      ),
      _caption('显示类型'),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          FilterChip(
            key: const ValueKey('danmaku-mode-scroll'),
            label: const Text('滚动'),
            selected: _style.scroll,
            onSelected: (value) => _update(_style.copyWith(scroll: value)),
          ),
          FilterChip(
            key: const ValueKey('danmaku-mode-top'),
            label: const Text('顶部固定'),
            selected: _style.top,
            onSelected: (value) => _update(_style.copyWith(top: value)),
          ),
          FilterChip(
            key: const ValueKey('danmaku-mode-bottom'),
            label: const Text('底部固定'),
            selected: _style.bottom,
            onSelected: (value) => _update(_style.copyWith(bottom: value)),
          ),
        ],
      ),
      SwitchListTile.adaptive(
        key: const ValueKey('danmaku-subtitle-safe'),
        contentPadding: EdgeInsets.zero,
        title: const Text('字幕避让'),
        subtitle: const Text('为底部字幕预留画面空间'),
        value: _style.subtitleSafe,
        onChanged: (value) => _update(_style.copyWith(subtitleSafe: value)),
      ),
    ]),
  );
  Widget _advanced() => KeyedSubtree(
    key: const ValueKey('danmaku-advanced-list'),
    child: _list([
      if (widget.timingControls != null) ...[
        widget.timingControls!,
        const SizedBox(height: 16),
      ],
      _caption('内容过滤'),
      ListTile(
        contentPadding: EdgeInsets.zero,
        key: const ValueKey('danmaku-keywords'),
        title: const Text('屏蔽关键词'),
        subtitle: Text('${_style.keywords.length} 个关键词'),
        trailing: const Icon(Icons.edit_outlined),
        onTap: _editKeywords,
      ),
      if (_style.keywords.isNotEmpty)
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final word in _style.keywords)
              InputChip(
                label: Text(word),
                onDeleted: () => _update(
                  _style.copyWith(
                    keywords: _style.keywords
                        .where((value) => value != word)
                        .toList(),
                  ),
                ),
              ),
          ],
        ),
      SwitchListTile.adaptive(
        key: const ValueKey('danmaku-block-colored'),
        contentPadding: EdgeInsets.zero,
        title: const Text('屏蔽彩色弹幕'),
        subtitle: const Text('过滤来源中带颜色的弹幕'),
        value: _style.blockColored,
        onChanged: (value) => _update(_style.copyWith(blockColored: value)),
      ),
      const SizedBox(height: 20),
      OutlinedButton.icon(
        key: const ValueKey('danmaku-reset-style'),
        onPressed: () => _update(const DanmakuStyle()),
        icon: const Icon(Icons.restart_alt_rounded),
        label: const Text('恢复默认样式与过滤'),
      ),
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          '保留数据源、匹配记录和分集时间偏移。',
          style: TextStyle(fontSize: 12, color: Colors.white60),
        ),
      ),
    ]),
  );
  Future<void> _editKeywords() async {
    final words = await showDialog<List<String>>(
      context: context,
      builder: (_) => _KeywordsDialog(words: _style.keywords),
    );
    if (words != null && mounted) _update(_style.copyWith(keywords: words));
  }
}

class _KeywordsDialog extends StatefulWidget {
  const _KeywordsDialog({required this.words});
  final List<String> words;
  @override
  State<_KeywordsDialog> createState() => _KeywordsDialogState();
}

class _KeywordsDialogState extends State<_KeywordsDialog> {
  late final _input = TextEditingController(text: widget.words.join('\n'));
  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('屏蔽关键词'),
    content: SizedBox(
      width: 400,
      child: TextField(
        key: const ValueKey('danmaku-keywords-input'),
        controller: _input,
        minLines: 3,
        maxLines: 7,
        maxLength: 6000,
        decoration: const InputDecoration(hintText: '每行一个，最多 100 个关键词'),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          DanmakuStyle.fromJson({
            'keywords': _input.text.split(RegExp(r'[\r\n]+')),
          }).keywords,
        ),
        child: const Text('保存'),
      ),
    ],
  );
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }
}
