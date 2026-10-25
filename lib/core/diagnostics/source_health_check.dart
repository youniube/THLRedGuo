import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:THLRedLook/core/js/catpaw_js_runtime.dart';
import 'package:THLRedLook/core/player/js_playback.dart';
import 'package:THLRedLook/models/catalog/models.dart';
import 'source_diagnostics.dart';

class SourceHealthChecks {
  SourceHealthChecks({required this.scriptFor, required this.client});

  final String? Function(String source) scriptFor;
  final http.Client client;
  final _tasks = <String, _SourceHealthTask>{};

  Map<String, dynamic> status(String source) =>
      _tasks[source]?.snapshot() ??
      {
        'source': source,
        'ready': scriptFor(source)?.isNotEmpty == true,
        'running': false,
        'stage': '就绪',
      };

  Map<String, dynamic> start(
    String source, {
    bool catalogOnly = false,
    Map<String, dynamic>? drama,
  }) {
    if (_tasks[source]?.status['running'] == true) return status(source);
    final task = _SourceHealthTask(source, catalogOnly);
    _tasks[source] = task;
    unawaited(_run(task, drama));
    return task.snapshot();
  }

  Map<String, dynamic> cancel(String source) {
    final task = _tasks[source];
    if (task == null || task.status['running'] != true) return status(source);
    task.cancelled = true;
    task.runtime?.cancelPending();
    if (task.abort?.isCompleted == false) task.abort!.complete();
    task.status.addAll({
      'running': false,
      'stage': '检测已停止',
      'finishedAt': DateTime.now().toIso8601String(),
    });
    task.health['state'] = 'cancelled';
    for (final step in task.steps) {
      if (step['state'] == 'checking') {
        step.addAll({'state': 'cancelled', 'message': '检测已停止'});
      }
    }
    return task.snapshot();
  }

  void remove(String source) {
    cancel(source);
    _tasks.remove(source);
  }

  void clear() {
    for (final source in _tasks.keys.toList()) {
      remove(source);
    }
  }

  void _active(_SourceHealthTask task) {
    if (task.cancelled || !identical(_tasks[task.source], task)) {
      throw CatPawSourceFailure.playback('cancelled');
    }
  }

  Future<void> _step(
    _SourceHealthTask task,
    String name,
    Future<String> Function() action,
  ) async {
    _active(task);
    task.status['stage'] = name;
    final step = <String, dynamic>{
      'name': name,
      'state': 'checking',
      'message': '检测中',
    };
    task.steps.add(step);
    final clock = Stopwatch()..start();
    try {
      final message = await action();
      _active(task);
      step.addAll({'state': 'ok', 'message': message});
      task.status['completed'] = task.steps.length;
    } catch (error) {
      if (!task.cancelled) {
        step.addAll({
          'state': 'failed',
          'message': SourceDiagnostics.analyzeError(error).message,
        });
      }
      rethrow;
    } finally {
      step['elapsedMs'] = clock.elapsedMilliseconds;
    }
  }

  Future<void> _run(_SourceHealthTask task, Map<String, dynamic>? drama) async {
    try {
      final script = scriptFor(task.source);
      late CatPawJsRuntime browsing;
      await _step(task, '脚本与 JS 引擎', () async {
        if (script == null || script.isEmpty) throw StateError('站源脚本未加载');
        browsing = CatPawJsRuntime(
          null,
          SourceDiagnostics.shared,
          '站源检测 ${task.source}',
        );
        task.runtime = browsing;
        await browsing.init(script);
        return '脚本加载成功';
      });
      late CatPawHomeResult home;
      await _step(task, '分类连接', () async {
        home = await browsing.home(filter: task.source == 'hongguo');
        if (home.classes.isEmpty) throw StateError('站源未返回分类');
        return '返回 ${home.classes.length} 个分类';
      });
      late CatPawCategoryResult catalog;
      await _step(task, '目录连接', () async {
        catalog = await browsing.category(
          home.classes.first['type_id']?.toString() ?? '',
          1,
        );
        return '返回 ${catalog.list.length} 部作品';
      });
      if (task.catalogOnly) {
        task.health['state'] = 'catalogOnly';
        task.status['stage'] = '目录检测完成';
        return;
      }
      late Map<String, dynamic> chapter;
      await _step(task, '详情与选集', () async {
        final selectedDrama = drama != null && drama['source'] == task.source
            ? Drama.fromJson(drama)
            : null;
        final candidates = <Map<String, dynamic>>[
          if (selectedDrama != null)
            {
              'vod_id': selectedDrama.cleanSourceId,
              'vod_name': selectedDrama.title,
            }
          else
            ...catalog.list,
        ];
        Object? lastError;
        for (final sample in candidates.take(3)) {
          _active(task);
          final id = sample['vod_id']?.toString() ?? '';
          if (id.isEmpty) continue;
          try {
            final detail = await browsing.detail(id);
            final chapters = jsPlaybackChapters(
              detail.vod['vod_play_url']?.toString() ?? '',
              detail.vod['vod_play_from']?.toString() ?? '',
            );
            if (chapters.isEmpty) throw StateError('详情未返回有效选集');
            chapter = chapters.firstWhere(
              (row) => !RegExp(r'受限|付费|锁定').hasMatch('${row['title']}'),
              orElse: () => chapters.first,
            );
            task.health['sample'] =
                detail.vod['vod_name']?.toString() ??
                sample['vod_name']?.toString() ??
                '';
            return '返回 ${chapters.length} 集';
          } catch (error) {
            _active(task);
            lastError = error;
          }
        }
        throw lastError ?? StateError('目录没有可用于检测的作品');
      });
      late CatPawPlayResult play;
      await _step(task, '独立播放取流', () async {
        browsing.dispose();
        final playback = CatPawJsRuntime(
          null,
          SourceDiagnostics.shared,
          '站源检测 ${task.source}',
        );
        task.runtime = playback;
        await playback.init(script!);
        final route = (chapter['routes'] as List).first as Map;
        play = await playback.play(
          route['flag']?.toString() ?? 'flag',
          route['raw']?.toString() ?? '',
          flags: const [
            {'quality': 0},
          ],
        );
        if (play.url.isEmpty && play.streams.isEmpty) {
          throw CatPawSourceFailure.playback(play.errorCode);
        }
        return '独立运行时取流成功';
      });
      await _step(task, '媒体连接', () async {
        Object? lastError;
        final seen = <String>{};
        final candidates = [play, ...play.streams].where(
          (stream) =>
              stream.url.isNotEmpty &&
              stream.parse == 0 &&
              seen.add(stream.url),
        );
        for (final stream in candidates.take(3)) {
          _active(task);
          try {
            await _probe(task, stream);
            return '媒体地址可访问（未执行解码播放）';
          } catch (error) {
            _active(task);
            lastError = error;
          }
        }
        throw lastError ?? StateError('没有可检测的 HTTP(S) 媒体地址');
      });
      task.health['state'] = 'ok';
      task.status['stage'] = '检测完成';
    } catch (error) {
      if (!task.cancelled && identical(_tasks[task.source], task)) {
        task.health['state'] = 'failed';
        task.status.addAll({
          'stage': '检测失败',
          'error': SourceDiagnostics.analyzeError(error).message,
        });
      }
    } finally {
      task.runtime?.dispose();
      if (task.abort?.isCompleted == false) task.abort!.complete();
      task.status.addAll({
        'running': false,
        'finishedAt': DateTime.now().toIso8601String(),
      });
    }
  }

  Future<void> _probe(_SourceHealthTask task, CatPawPlayResult stream) async {
    final uri = Uri.tryParse(stream.url);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw StateError('媒体地址不是 HTTP(S) 地址');
    }
    final abort = Completer<void>();
    task.abort = abort;
    var timedOut = false;
    final timer = Timer(const Duration(seconds: 12), () {
      timedOut = true;
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final request = http.AbortableRequest(
        'GET',
        uri,
        abortTrigger: abort.future,
      )..headers.addAll({...stream.header, 'Range': 'bytes=0-1023'});
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 12));
      task.steps.last.addAll({
        'host': response.request?.url.host ?? uri.host,
        'httpStatus': response.statusCode,
        'cfRay': response.headers['cf-ray'] ?? '',
      });
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen((_) {}).cancel();
        throw StateError('媒体接口 HTTP ${response.statusCode}');
      }
      final bytes = await response.stream.first.timeout(
        const Duration(seconds: 12),
      );
      final type = response.headers['content-type'] ?? '';
      if (bytes.isEmpty ||
          type.contains('text/html') ||
          type.contains('application/json')) {
        throw const FormatException('媒体接口未返回视频或播放列表');
      }
    } catch (error) {
      if (timedOut) throw TimeoutException('媒体连接超时');
      rethrow;
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
      if (identical(task.abort, abort)) task.abort = null;
    }
  }
}

class _SourceHealthTask {
  _SourceHealthTask(this.source, this.catalogOnly) {
    final now = DateTime.now().toIso8601String();
    health = {
      'state': 'checking',
      'checkedAt': now,
      'sample': '',
      'steps': steps,
    };
    status = {
      'source': source,
      'ready': true,
      'running': true,
      'operation': catalogOnly ? 'checkCatalog' : 'check',
      'stage': '准备检测',
      'startedAt': now,
      'completed': 0,
      'total': catalogOnly ? 3 : 6,
      'error': '',
      'health': health,
    };
  }

  final String source;
  final bool catalogOnly;
  final steps = <Map<String, dynamic>>[];
  late final Map<String, dynamic> status, health;
  bool cancelled = false;
  CatPawJsRuntime? runtime;
  Completer<void>? abort;

  Map<String, dynamic> snapshot() => {
    ...status,
    'health': {
      ...health,
      'steps': [
        for (final step in steps) {...step},
      ],
    },
  };
}
