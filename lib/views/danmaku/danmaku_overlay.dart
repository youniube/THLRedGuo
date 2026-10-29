import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:THLRedLook/utils/theme/app_colors.dart';
import 'package:THLRedLook/core/danmaku/danmaku_controller.dart';
import 'package:THLRedLook/models/danmaku/danmaku_models.dart';

class DanmakuFlight {
  const DanmakuFlight(
    this.item,
    this.text,
    this.lane,
    this.width,
    this.durationMs,
  );
  final DanmakuItem item;
  final String text;
  final int lane;
  final double width;
  final int durationMs;
}

int calculateDanmakuLifetimeMs(DanmakuItem item) {
  final hash = item.id.hashCode.abs();
  final factor = (hash % 1000) / 1000.0;
  final offset = ((factor - 0.5) * 3000).round();
  return (8000 + offset).clamp(6500, 9800);
}

List<DanmakuFlight> planDanmaku(
  List<DanmakuItem> items, {
  required double width,
  required int rows,
  required double Function(String) measure,
  int? totalRows,
  DanmakuStyle style = const DanmakuStyle(),
}) {
  if (!width.isFinite || width <= 0 || (totalRows ?? rows) < 1) return const [];
  final laneCount = (totalRows ?? rows).clamp(1, 16);
  final bottomRows =
      style.bottom &&
          (totalRows != null ||
              items.any(
                (item) =>
                    item.mode == DanmakuMode.bottom && style.accepts(item),
              ))
      ? math.min(2, laneCount)
      : 0;
  final regularRows = math.min(
    rows.clamp(0, laneCount),
    laneCount - bottomRows,
  );
  final gapSize = switch (style.density) {
    DanmakuDensity.low => 64.0,
    DanmakuDensity.medium => 28.0,
    DanmakuDensity.high => 16.0,
  };
  final capacity = switch (style.density) {
    DanmakuDensity.low => 12,
    DanmakuDensity.medium => 40,
    DanmakuDensity.high => 60,
  };
  final lanes = List<DanmakuFlight?>.filled(laneCount, null);
  final sorted = items.toList()..sort((a, b) => a.timeMs.compareTo(b.timeMs));
  final seen = <String>{};
  final flights = <DanmakuFlight>[];

  for (final item in sorted) {
    if (item.id.isEmpty ||
        item.text.trim().isEmpty ||
        item.timeMs < 0 ||
        !style.accepts(item) ||
        !seen.add(item.id)) {
      continue;
    }
    if (flights
            .where(
              (flight) => item.timeMs < flight.item.timeMs + flight.durationMs,
            )
            .length >=
        capacity) {
      continue;
    }
    final runes = item.text.runes;
    final text =
        String.fromCharCodes(runes.take(100)) + (runes.length > 100 ? '…' : '');
    final measured = measure(text);
    if (!measured.isFinite || measured <= 0) continue;
    final size = measured.ceilToDouble() + 8;
    final durationMs = item.mode == DanmakuMode.scroll
        ? (calculateDanmakuLifetimeMs(item) / style.speed.clamp(.5, 2)).round()
        : 4000;

    int bestLane = -1;
    double maxSafetyMargin = -1;

    final candidates = item.mode == DanmakuMode.bottom
        ? List.generate(bottomRows, (index) => laneCount - index - 1)
        : List.generate(regularRows, (index) => index);
    for (final l in candidates) {
      final prev = lanes[l];
      if (prev == null) {
        bestLane = l;
        break;
      }
      final gap = item.timeMs - prev.item.timeMs;
      if (gap >= prev.durationMs) {
        bestLane = l;
        break;
      }
      if (item.mode != DanmakuMode.scroll ||
          prev.item.mode != DanmakuMode.scroll) {
        continue;
      }
      final prevSpeed = (width + prev.width) / prev.durationMs;
      final prevMovedAtEntry = prevSpeed * gap;
      final entryClearance = prevMovedAtEntry - prev.width;
      if (entryClearance < gapSize) {
        continue;
      }

      final currSpeed = (width + size) / durationMs;
      final remainingTime = prev.durationMs - gap;
      final currMovedAtPrevExit = currSpeed * remainingTime;
      final exitClearance = width - currMovedAtPrevExit;
      if (exitClearance < gapSize) {
        continue;
      }

      final safetyMargin = math.min(entryClearance, exitClearance);
      if (safetyMargin > maxSafetyMargin) {
        maxSafetyMargin = safetyMargin;
        bestLane = l;
      }
    }

    if (bestLane < 0) continue;

    final flight = DanmakuFlight(item, text, bestLane, size, durationMs);
    lanes[bestLane] = flight;
    flights.add(flight);
  }
  return flights;
}

TextStyle danmakuTextStyle(
  DanmakuStyle settings,
  double fontSize, {
  int itemColor = 0xffffff,
}) {
  final opacity = settings.opacity.clamp(.1, 1.0);
  return TextStyle(
    fontSize: fontSize,
    fontWeight: FontWeight.w600,
    height: 1.2,
    color: Color(
      0xff000000 | (settings.useOriginalColor ? itemColor : settings.color),
    ).withValues(alpha: opacity),
    shadows: [
      if (settings.outline)
        for (final offset in const [
          Offset(1, 0),
          Offset(-1, 0),
          Offset(0, 1),
          Offset(0, -1),
        ])
          Shadow(
            color: AppColors.black.withValues(alpha: opacity),
            offset: offset,
          ),
      if (settings.shadow)
        Shadow(
          color: AppColors.black.withValues(alpha: opacity * .85),
          blurRadius: 3,
          offset: const Offset(1, 1),
        ),
    ],
  );
}

class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.controller,
    required this.aspectRatio,
    this.style = const DanmakuStyle(),
  });
  final DanmakuController controller;
  final double aspectRatio;
  final DanmakuStyle style;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay> {
  Object? _layout;
  List<DanmakuFlight> _schedule = const [];

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (!constraints.hasBoundedWidth ||
              !constraints.hasBoundedHeight ||
              constraints.maxWidth <= 0 ||
              constraints.maxHeight <= 0) {
            return const SizedBox.shrink();
          }
          final aspect = widget.aspectRatio.isFinite && widget.aspectRatio > 0
              ? widget.aspectRatio
              : 16 / 9;
          final width = math.min(
            constraints.maxWidth,
            constraints.maxHeight * aspect,
          );
          final height = math.min(
            constraints.maxHeight,
            constraints.maxWidth / aspect,
          );
          final baseFontSize = width < 600 ? 16.0 : 20.0;
          final fontSize = baseFontSize * widget.style.fontSizeScale;
          final scaler = MediaQuery.textScalerOf(context);
          final rowHeight = scaler.scale(fontSize) * 1.5;
          final bottomInset = widget.style.subtitleSafe ? height * .12 : 8.0;
          final totalRows = ((height - bottomInset - 8) / rowHeight)
              .floor()
              .clamp(0, 16);
          final rows = math.min(
            totalRows,
            ((height * widget.style.displayArea - 8) / rowHeight).floor().clamp(
              0,
              16,
            ),
          );
          final style = danmakuTextStyle(widget.style, fontSize);
          return Center(
            child: SizedBox(
              width: width,
              height: height,
              child: ClipRect(
                child: AnimatedBuilder(
                  animation: widget.controller,
                  builder: (context, _) {
                    final controller = widget.controller;
                    if (!controller.visible || totalRows == 0) {
                      return const SizedBox.shrink();
                    }
                    final layout = (
                      controller,
                      controller.dataRevision,
                      width,
                      rows,
                      totalRows,
                      fontSize,
                      scaler,
                      widget.style,
                    );
                    if (_layout != layout) {
                      _layout = layout;
                      _schedule = planDanmaku(
                        controller.items,
                        width: width,
                        rows: rows,
                        totalRows: totalRows,
                        style: widget.style,
                        measure: (text) {
                          final painter = TextPainter(
                            text: TextSpan(text: text, style: style),
                            textDirection: TextDirection.ltr,
                            textScaler: scaler,
                            maxLines: 1,
                          )..layout();
                          final measured = painter.width;
                          painter.dispose();
                          return measured;
                        },
                      );
                    }
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (final flight in _schedule)
                          if (controller.positionMs >= flight.item.timeMs &&
                              controller.positionMs <
                                  flight.item.timeMs + flight.durationMs)
                            Positioned(
                              key: ValueKey('danmaku-item-${flight.item.id}'),
                              left: 0,
                              top: 8 + flight.lane * rowHeight,
                              width: flight.width,
                              height: rowHeight,
                              child: _DanmakuMotion(
                                flight: flight,
                                width: width,
                                positionMs: controller.positionMs,
                                moving: controller.moving,
                                rate: controller.rate,
                                revision: controller.motionRevision,
                                style: danmakuTextStyle(
                                  widget.style,
                                  fontSize,
                                  itemColor: flight.item.color,
                                ),
                                scaler: scaler,
                              ),
                            ),
                      ],
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

class _DanmakuMotion extends StatefulWidget {
  const _DanmakuMotion({
    required this.flight,
    required this.width,
    required this.positionMs,
    required this.moving,
    required this.rate,
    required this.revision,
    required this.style,
    required this.scaler,
  });
  final DanmakuFlight flight;
  final double width;
  final int positionMs;
  final bool moving;
  final double rate;
  final int revision;
  final TextStyle style;
  final TextScaler scaler;

  @override
  State<_DanmakuMotion> createState() => _DanmakuMotionState();
}

class _DanmakuMotionState extends State<_DanmakuMotion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(vsync: this);

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_DanmakuMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision ||
        oldWidget.positionMs != widget.positionMs ||
        oldWidget.width != widget.width ||
        oldWidget.flight.width != widget.flight.width ||
        oldWidget.flight.item.timeMs != widget.flight.item.timeMs ||
        oldWidget.flight.durationMs != widget.flight.durationMs) {
      _sync();
    }
    if (oldWidget.style != widget.style || oldWidget.scaler != widget.scaler) {
      setState(() {});
    }
  }

  void _sync() {
    _motion.stop();
    final lifetime = widget.flight.durationMs;
    final elapsed = (widget.positionMs - widget.flight.item.timeMs).clamp(
      0,
      lifetime,
    );
    _motion.value = elapsed / lifetime;
    if (widget.moving && elapsed < lifetime) {
      _motion.animateTo(
        (elapsed + 750).clamp(0, lifetime) / lifetime,
        duration: Duration(
          microseconds:
              ((lifetime - elapsed).clamp(1, 750) * 1000 / widget.rate)
                  .round()
                  .clamp(1, 86400000000),
        ),
        curve: Curves.linear,
      );
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _motion,
    child: RepaintBoundary(
      child: Text(
        widget.flight.text,
        style: widget.style,
        textScaler: widget.scaler,
        textDirection: TextDirection.ltr,
        maxLines: 1,
        softWrap: false,
      ),
    ),
    builder: (context, child) => Transform.translate(
      key: ValueKey('danmaku-motion-${widget.flight.item.id}'),
      offset: Offset(
        widget.flight.item.mode == DanmakuMode.scroll
            ? widget.width -
                  (widget.width + widget.flight.width) * _motion.value
            : (widget.width - widget.flight.width) / 2,
        0,
      ),
      child: child,
    ),
  );
}
