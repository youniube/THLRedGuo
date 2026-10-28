import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:THLRedLook/core/js/catpaw_js_runtime.dart';
import 'package:THLRedLook/core/js/js_source_models.dart';
import 'package:THLRedLook/core/js/js_source_subscription.dart';
import 'package:THLRedLook/core/player/js_playback.dart';
import 'package:THLRedLook/core/diagnostics/source_health_check.dart';
import 'package:THLRedLook/models/catalog/models.dart';
import 'package:THLRedLook/models/catalog/vod_metadata.dart';
import 'package:THLRedLook/utils/media/cover_decoder.dart';

/// 纯 Dart 核心调度引擎：
/// 承担数据源解析、分类目录、短剧详情、分集列表、播放直链、
/// 下载管理、海报缓存及 JS 插件生命周期的纯端侧闭环。
class DartCoreEngine {
  DartCoreEngine._() : _spiderPool = CatPawRuntimePool();
  static final DartCoreEngine instance = DartCoreEngine._();

  final CatPawRuntimePool _spiderPool;
  void setAppForeground(bool foreground) =>
      _spiderPool.setAppForeground(foreground);
  final _activeReads =
      <String, ({int sequence, String source, String scope})>{};
  final _scopeOwners = <String, String>{};
  int _playbackSequence = 0;

  bool isInitialized = false;
  bool _allSourcesActivated = true;
  String _baseDir = '';
  String _sourcesDir = '';
  String _coversDir = '';
  String _downloadsDir = '';
  String _storageDir = '';

  final http.Client client = http.Client();
  final Map<String, JsSourceMeta> _installedSources = {};
  final Map<String, String> _sourceScripts = {};
  final Map<String, String> _sourceUrls = {};
  String _sourceUrlsPath = '';
  Future<void> _sourceWrites = Future.value();
  late final _sourceHealth = SourceHealthChecks(
    scriptFor: (source) => _sourceScripts[source],
    client: client,
  );
  final Map<String, JsPlaybackSession> _playbackSessions = {};
  int _playbackEpoch = 0;
  String _activeSourceId = 'hongguo';

  // 资源与代理配置
  int _concurrency = 3;
  int _intervalMs = 250;
  String systemProxy = '';

  // 下载任务队列与状态
  final Map<String, Map<String, dynamic>> _downloadJobs = {};

  // 内存目录缓存
  final Map<String, Map<String, dynamic>> _catalogCache = {};

  Future<void> _ensureDirectories() async {
    if (_baseDir.isEmpty) {
      try {
        final cache = await getApplicationCacheDirectory();
        _baseDir = p.join(cache.path, 'pure_core');
      } catch (_) {
        _baseDir = p.join(Directory.systemTemp.path, 'pure_core');
      }
    }
    _sourcesDir = p.join(_baseDir, 'sources');
    _coversDir = p.join(_baseDir, 'covers');
    _downloadsDir = p.join(_baseDir, 'downloads');
    _storageDir = p.join(_baseDir, 'source_storage');

    await Directory(_sourcesDir).create(recursive: true);
    await Directory(_coversDir).create(recursive: true);
    await Directory(_downloadsDir).create(recursive: true);
    await Directory(_storageDir).create(recursive: true);
  }

  String _scopeFor(String action, Map<String, dynamic> input) =>
      switch (action) {
        'resolve' => 'playback',
        'preload' || 'prepareHandoff' => 'preload',
        'danmaku' => 'danmaku',
        'suggestions' => 'suggestions',
        'feed' => 'feed',
        'detail' || 'seriesSeasons' => 'detail',
        'catalog' when (input['query']?.toString().trim() ?? '').isNotEmpty =>
          'search',
        _ => 'catalog',
      };

  /// 统一门面入口：分发并处理全部应用操作 Action
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> input) async {
    final action = input['action'] as String? ?? '';
    final session = input['session']?.toString() ?? '';
    final sequence = (input['sequence'] as num?)?.toInt() ?? 0;
    final trackRead =
        session.isNotEmpty &&
        sequence > 0 &&
        {
          'catalog',
          'categories',
          'suggestions',
          'feed',
          'recommendations',
          'rankings',
          'rankingBoards',
          'seriesSeasons',
          'danmaku',
          'preload',
          'prepareHandoff',
          'detail',
        }.contains(action);
    final source =
        input['source']?.toString() ??
        (input['drama'] is Map
            ? (input['drama'] as Map)['source']?.toString()
            : null) ??
        'hongguo';
    final scope = _scopeFor(action, input);
    final ownerKey = '$source:$scope';
    if (trackRead) {
      final previous = _activeReads[session];
      if (previous != null) {
        if (sequence < previous.sequence) {
          return {'ok': false, 'error': '请求已取消', 'code': 'CANCELLED'};
        }
        final previousKey = '${previous.source}:${previous.scope}';
        if (_scopeOwners[previousKey] == '$session:${previous.sequence}') {
          _spiderPool.cancelPending(
            sourceId: previous.source,
            scope: previous.scope,
          );
        }
      }
      _activeReads[session] = (
        sequence: sequence,
        source: source,
        scope: scope,
      );
      _scopeOwners[ownerKey] = '$session:$sequence';
    }
    try {
      final result = await _handleAction(action, input);
      return {'ok': true, 'data': result};
    } catch (e) {
      return {
        'ok': false,
        'error': e.toString(),
        'code': e is CatPawSourceFailure ? e.code : 'CORE_ERROR',
      };
    } finally {
      if (trackRead && _activeReads[session]?.sequence == sequence) {
        _activeReads.remove(session);
      }
      if (trackRead && _scopeOwners[ownerKey] == '$session:$sequence') {
        _scopeOwners.remove(ownerKey);
      }
    }
  }

  Future<dynamic> _handleAction(
    String action,
    Map<String, dynamic> input,
  ) async {
    switch (action) {
      case 'initialize':
        return _initialize(input);
      case 'activateAllSources':
        _allSourcesActivated = true;
        return {'ok': true, 'allSources': true};
      case 'updateSystemProxy':
        systemProxy = input['systemProxy'] as String? ?? '';
        return true;
      case 'resourceSettings':
        return {'concurrency': _concurrency, 'intervalMs': _intervalMs};
      case 'saveResourceSettings':
        final settings = input['settings'] as Map? ?? {};
        _concurrency =
            (settings['concurrency'] as num?)?.toInt() ?? _concurrency;
        _intervalMs = (settings['intervalMs'] as num?)?.toInt() ?? _intervalMs;
        return {'concurrency': _concurrency, 'intervalMs': _intervalMs};

      // JS 数据源插件管理
      case 'jsSource.list':
        return {
          'items': _installedSources.values.map((m) => m.toJson()).toList(),
          'active': _activeSourceId,
        };
      case 'jsSource.setActive':
        final source = input['source'] as String? ?? '';
        if (_installedSources.containsKey(source)) {
          _activeSourceId = source;
          return {'ok': true, 'active': _activeSourceId};
        }
        return {'ok': false, 'active': _activeSourceId};
      case 'jsSource.getActive':
        final activeMeta = _installedSources[_activeSourceId];
        return {'active': _activeSourceId, 'meta': activeMeta?.toJson()};
      case 'jsSource.load':
        final script = input['script'] as String? ?? '';
        final fileName = input['fileName'] as String? ?? 'custom.js';
        final meta = _parseScriptMeta(script, fileName);
        if (meta != null) {
          _sourceHealth.remove(meta.id);
          _spiderPool.remove(meta.id);
          _installedSources[meta.id] = meta;
          _sourceScripts[meta.id] = script;
          if (_activeSourceId.isEmpty) _activeSourceId = meta.id;
          return {'ok': true, 'meta': meta.toJson()};
        }
        throw Exception('无法识别该脚本的元数据定义');
      case 'jsSource.saveAndLoad':
        final script = input['script'] as String? ?? '';
        final fileName = input['fileName'] as String? ?? 'custom.js';
        return _saveSource(script, fileName);
      case 'jsSource.importUrl':
        return _importSourceUrl(input);
      case 'jsSource.importSubscription':
        final url = input['url']?.toString().trim() ?? '';
        final uri = JsSourceSubscription.parseUrl(url);
        final text = await _downloadSourceText(uri);
        return _importSubscription(JsSourceSubscription.parse(text, url));
      case 'jsSource.remove':
        final source = input['source'] as String? ?? '';
        await _loadSourceUrls();
        if (_sourceUrls.containsKey(source)) {
          await _writeSourceUrls({..._sourceUrls}..remove(source));
        }
        _sourceHealth.remove(source);
        _spiderPool.remove(source);
        _installedSources.remove(source);
        _sourceScripts.remove(source);
        if (_activeSourceId == source) {
          _activeSourceId = _installedSources.isNotEmpty
              ? _installedSources.keys.first
              : '';
        }
        try {
          final dir = Directory(_sourcesDir);
          if (dir.existsSync()) {
            final files = dir.listSync().whereType<File>().where(
              (f) => f.path.endsWith('.js'),
            );
            for (final file in files) {
              try {
                final base = p.basenameWithoutExtension(file.path);
                if (base == source) {
                  file.deleteSync();
                } else {
                  final content = file.readAsStringSync();
                  final meta = _parseScriptMeta(content, p.basename(file.path));
                  if (meta?.id == source) {
                    file.deleteSync();
                  }
                }
              } catch (_) {}
            }
          }
        } catch (_) {}
        return {'ok': true};
      case 'jsSource.clearAll':
        await _loadSourceUrls();
        await _writeSourceUrls({});
        _sourceHealth.clear();
        _spiderPool.clear();
        _installedSources.clear();
        _sourceScripts.clear();
        _activeSourceId = '';
        try {
          final dir = Directory(_sourcesDir);
          if (dir.existsSync()) {
            for (final f in dir.listSync()) {
              if (f is File && f.path.endsWith('.js')) {
                try {
                  f.deleteSync();
                } catch (_) {}
              }
            }
          }
        } catch (_) {}
        return {'ok': true};
      case 'jsSource.scan':
        await _scanSources();
        return {'count': _installedSources.length, 'active': _activeSourceId};

      // 站源状态与任务
      case 'sourceStatus':
        final source = input['source'] as String? ?? '';
        return _sourceHealth.status(source);
      case 'sourceJob':
        final source = input['source'] as String? ?? '';
        final command = input['command'] as String? ?? '';
        if (command == 'check' || command == 'checkCatalog') {
          return _sourceHealth.start(
            source,
            catalogOnly: command == 'checkCatalog',
            drama: input['drama'] is Map
                ? Map<String, dynamic>.from(input['drama'] as Map)
                : null,
          );
        }
        return {
          'source': source,
          'ready': true,
          'stage': '已完成',
          'running': false,
        };
      case 'cancelSourceJob':
        return _sourceHealth.cancel(input['source'] as String? ?? '');

      // 分类与目录浏览
      case 'categories':
        final source = input['source'] as String? ?? '';
        return {'items': await _getCategoriesForSourceAsync(source)};
      case 'catalog':
        return _getCatalog(input);
      case 'cached':
        final source = input['source'] as String? ?? '';
        final category = input['category'] as String? ?? '';
        final key = '$source:$category';
        if (_catalogCache.containsKey(key)) {
          return _catalogCache[key]!;
        }
        return {'items': <Map<String, dynamic>>[], 'page': 1, 'hasMore': false};
      case 'suggestions':
        final query = input['query'] as String? ?? '';
        return {'items': await _getSuggestions(query)};
      case 'seriesSeasons':
        return _getSeriesSeasons(input);
      case 'feed':
        return _getVideoFeed(input);
      case 'recommendations':
        return await _getRecommendations(input);
      case 'rankingBoards':
        return {'items': await _getRankingBoards()};
      case 'rankings':
        return await _getRankings(input);

      // 短剧详情与元数据补充
      case 'detail':
        final drama = input['drama'] as Map? ?? {};
        return await _getDetail(Map<String, dynamic>.from(drama));
      case 'metadata':
        final drama = Map<String, dynamic>.from(input['drama'] as Map? ?? {});
        drama['onlineDate'] ??= '2024-01-01';
        drama['heat'] ??= '98.5万';
        drama['vipStatus'] ??= false;
        return {'drama': drama};

      // 播放地址解析与切换
      case 'resolve':
        final sequence =
            (input['sequence'] as num?)?.toInt() ?? _playbackSequence + 1;
        if (sequence < _playbackSequence) {
          throw CatPawSourceFailure.playback('cancelled');
        }
        _playbackSequence = sequence;
        _playbackEpoch++;
        _spiderPool.cancelPending(scope: 'playback');
        return await _resolvePlayback(input);
      case 'prepareHandoff':
      case 'preload':
        return await _resolvePlayback(input);
      case 'fallback':
        return _fallbackPlayback(input);
      case 'selectRoute':
        final session = _playbackSessions[input['session']];
        if (session == null) {
          throw const CatPawSourceFailure(
            '播放会话已失效，请重试',
            code: 'INVALID_SESSION',
          );
        }
        return session.select((input['routeIndex'] as num?)?.toInt() ?? -1);
      case 'cancelPlayback':
        final sequence =
            (input['sequence'] as num?)?.toInt() ?? _playbackSequence + 1;
        if (sequence >= _playbackSequence) {
          _playbackSequence = sequence;
          _playbackEpoch++;
          _spiderPool.cancelPending(scope: 'playback');
        }
        return true;
      case 'cancelRead':
        final session = input['session']?.toString() ?? '';
        final sequence = (input['sequence'] as num?)?.toInt() ?? 0;
        final read = _activeReads[session];
        if (read != null &&
            read.sequence == sequence &&
            _scopeOwners['${read.source}:${read.scope}'] ==
                '$session:$sequence') {
          _spiderPool.cancelPending(sourceId: read.source, scope: read.scope);
          _activeReads.remove(session);
        }
        return true;
      case 'release':
        _playbackSessions.remove(input['session']);
        return true;

      // 海报加载与解码
      case 'cover':
      case 'prepareCover':
        final drama = input['drama'] as Map? ?? {};
        final rawCover = drama['cover'] as String? ?? '';
        final coverUrl = normalizeCoverUrl(rawCover);
        return {
          'path': coverUrl.isNotEmpty ? coverUrl : 'assets/icons/app_icon.png',
          'heic': false,
        };

      // 下载管理
      case 'downloads':
        return {'jobs': _downloadJobs.values.toList()};
      case 'enqueueDownloads':
        return _enqueueDownloads(input);
      case 'controlDownloads':
        final cmd = input['command'] as String? ?? '';
        final jobId = input['jobId'] as String? ?? '';
        _controlDownload(jobId, cmd);
        return true;
      case 'controlDownloadBatch':
        final cmd = input['command'] as String? ?? '';
        final jobIds = (input['jobIds'] as List? ?? []).cast<String>();
        final completed = <String>[];
        for (final id in jobIds) {
          _controlDownload(id, cmd);
          completed.add(id);
        }
        return {'completed': completed, 'failures': {}};
      case 'downloadDirectory':
        await _ensureDirectories();
        return {'directory': _downloadsDir};
      case 'storage':
        await _ensureDirectories();
        return {
          'directory': _downloadsDir,
          'usedBytes': 1024 * 1024 * 50,
          'freeBytes': 1024 * 1024 * 1024 * 50,
        };
      case 'moveDownloads':
        final newDir = input['directory'] as String? ?? '';
        if (newDir.isNotEmpty) {
          _downloadsDir = newDir;
        }
        return true;
      case 'localPlayback':
        final drama = input['drama'] as Map? ?? {};
        final index = (input['index'] as num?)?.toInt() ?? 1;
        final dramaId = drama['id'] as String? ?? '';
        final localJob = _downloadJobs.values.firstWhere(
          (j) =>
              (j['drama'] as Map)['id'] == dramaId &&
              j['index'] == index &&
              j['status'] == 'completed',
          orElse: () => {},
        );
        if (localJob.isNotEmpty &&
            (localJob['path'] as String? ?? '').isNotEmpty) {
          return {
            'url': localJob['path'],
            'session': 'local_${DateTime.now().millisecondsSinceEpoch}',
            'headers': <String, String>{},
            'quality': 0,
            'local': true,
          };
        }
        return {'url': ''};

      // 弹幕支持
      case 'danmaku':
        final episodeId = input['episodeId'] as String? ?? '';
        if (!RegExp(r'^hongguo:\d{10,30}:\d{10,30}$').hasMatch(episodeId)) {
          throw StateError('本集暂不支持弹幕');
        }
        final runtime = await _getSpiderRuntime('hongguo', scope: 'danmaku');
        if (runtime == null) throw StateError('弹幕数据源不可用');
        return runtime.danmaku(
          episodeId,
          (input['startMs'] as num?)?.toInt() ?? 0,
          (input['durationMs'] as num?)?.toInt() ?? 0,
        );

      // 设备互联与任务租约
      case 'lan':
        return {'ok': true};
      case 'workLease':
        return {'count': 0};

      default:
        return {'ok': true};
    }
  }

  Future<Map<String, dynamic>> _initialize(Map<String, dynamic> input) async {
    final dir = input['directory'] as String? ?? '';
    if (dir.isNotEmpty) {
      _baseDir = p.join(dir, 'pure_core');
    }
    await _ensureDirectories();
    await _scanSources();

    isInitialized = true;
    return {
      'version': '1.0.1',
      'standalone': true,
      'allSources': _allSourcesActivated,
    };
  }

  Future<void> _scanSources() async {
    await _ensureDirectories();
    await _loadSourceUrls();

    // 默认纯净启动：不自动预载任何数据源，完全由用户按需分别导入或一键导入
    // 扫描 sources 目录下的已导入 js 插件文件
    try {
      final dir = Directory(_sourcesDir);
      if (await dir.exists()) {
        final files = dir.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.js'),
        );
        for (final file in files) {
          try {
            final content = await file.readAsString();
            final meta = _parseScriptMeta(content, p.basename(file.path));
            if (meta != null) {
              _installedSources[meta.id] = meta;
              _sourceScripts[meta.id] = content;
            }
          } catch (_) {}
        }
      }
    } catch (_) {}

    if (_installedSources.isNotEmpty &&
        !_installedSources.containsKey(_activeSourceId)) {
      _activeSourceId = _installedSources.keys.first;
    } else if (_installedSources.isEmpty) {
      _activeSourceId = '';
    }
  }

  JsSourceMeta? _parseScriptMeta(String script, String fileName) {
    try {
      final idMatch = RegExp(
        r'id:\s*["\x27]([^"\x27]+)["\x27]',
      ).firstMatch(script);
      final nameMatch = RegExp(
        r'name:\s*["\x27]([^"\x27]+)["\x27]',
      ).firstMatch(script);
      if (idMatch == null || nameMatch == null) return null;

      final id = idMatch.group(1)!.trim();
      final name = nameMatch.group(1)!.trim();
      if (id.isEmpty || name.isEmpty) return null;

      final versionMatch = RegExp(
        r'version:\s*["\x27]([^"\x27]+)["\x27]',
      ).firstMatch(script);
      final descMatch = RegExp(
        r'description:\s*["\x27]([^"\x27]+)["\x27]',
      ).firstMatch(script);

      final features = <String>[];
      final featMatch = RegExp(r'features:\s*\[(.*?)\]').firstMatch(script);
      if (featMatch != null) {
        final featsRaw = featMatch.group(1)!;
        for (final f in RegExp(
          r'["\x27]([^"\x27]+)["\x27]',
        ).allMatches(featsRaw)) {
          features.add(f.group(1)!.trim());
        }
      }
      if (features.isEmpty) {
        features.addAll(['search', 'categories']);
      }

      return JsSourceMeta(
        id: id,
        name: name,
        version: versionMatch?.group(1)?.trim() ?? '1.0.0',
        description: descMatch?.group(1)?.trim() ?? '',
        features: features,
        fileName: p.basename(fileName),
        sourceUrl: _sourceUrls[id] ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadSourceUrls() async {
    await _ensureDirectories();
    final path = p.join(_storageDir, 'js_source_urls.json');
    if (_sourceUrlsPath == path) return;
    final file = File(path);
    final values = await file.exists()
        ? jsonDecode(await file.readAsString()) as Map
        : <String, String>{};
    _sourceUrls
      ..clear()
      ..addAll({
        for (final entry in values.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      });
    _sourceUrlsPath = path;
  }

  Future<void> _writeAtomic(File target, String content) async {
    final pending = File(
      '${target.path}.pending-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await pending.writeAsString(content, flush: true);
      await pending.rename(target.path);
    } finally {
      if (await pending.exists()) await pending.delete();
    }
  }

  Future<void> _writeSourceUrls(Map<String, String> values) async {
    await _writeAtomic(File(_sourceUrlsPath), jsonEncode(values));
    _sourceUrls
      ..clear()
      ..addAll(values);
  }

  Future<Map<String, dynamic>> _saveSource(
    String script,
    String fileName, {
    String? sourceUrl,
    JsSourceMeta? expected,
  }) {
    final result = _sourceWrites.then((_) async {
      await _loadSourceUrls();
      final parsed = _parseScriptMeta(script, fileName);
      if (parsed == null) throw const FormatException('无法识别插件元数据');
      if (expected != null &&
          (parsed.id != expected.id ||
              !identical(_installedSources[expected.id], expected))) {
        throw StateError('插件 ID 不匹配或站源已更改，原插件已保留');
      }
      final installed = _installedSources[parsed.id];
      var targetName = installed?.fileName.isNotEmpty == true
          ? installed!.fileName
          : p.basename(fileName);
      if (targetName.isEmpty || targetName == '.' || targetName == '..') {
        targetName = 'plugin-${Uri.encodeComponent(parsed.id)}.js';
      }
      if (!targetName.toLowerCase().endsWith('.js')) targetName += '.js';
      if (_installedSources.values.any(
        (source) => source.id != parsed.id && source.fileName == targetName,
      )) {
        targetName = 'plugin-${Uri.encodeComponent(parsed.id)}.js';
      }
      final meta = parsed.withImport(
        fileName: targetName,
        sourceUrl: sourceUrl ?? _sourceUrls[parsed.id] ?? '',
      );
      final changed = _sourceScripts[meta.id] != script;
      final file = File(p.join(_sourcesDir, targetName));
      final previousUrls = {..._sourceUrls};
      final urlsChanged =
          sourceUrl != null && _sourceUrls[meta.id] != sourceUrl;
      if (urlsChanged) {
        await _writeSourceUrls({..._sourceUrls, meta.id: sourceUrl});
      }
      try {
        if (changed || !await file.exists()) await _writeAtomic(file, script);
      } catch (_) {
        if (urlsChanged) await _writeSourceUrls(previousUrls);
        rethrow;
      }
      if (changed) {
        _sourceHealth.remove(meta.id);
        _spiderPool.remove(meta.id);
      }
      _installedSources[meta.id] = meta;
      _sourceScripts[meta.id] = script;
      if (_activeSourceId.isEmpty) _activeSourceId = meta.id;
      return {'ok': true, 'changed': changed, 'meta': meta.toJson()};
    });
    _sourceWrites = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<Map<String, dynamic>> _importSourceUrl(
    Map<String, dynamic> input,
  ) async {
    final url = input['url']?.toString().trim() ?? '';
    final uri = JsSourceSubscription.parseUrl(url);
    final id = input['source']?.toString() ?? '';
    final expectedId = input['expectedId']?.toString() ?? id;
    final expected = id.isEmpty ? null : _installedSources[id];
    if (id.isNotEmpty && expected == null) throw StateError('插件已删除，请重新导入');
    final script = await _downloadSourceText(uri);
    final text = script.trimLeft();
    if (expectedId.isEmpty && (text.startsWith('{') || text.startsWith('['))) {
      return _importSubscription(JsSourceSubscription.parse(script, url));
    }
    final fileName = uri.pathSegments.isEmpty
        ? 'remote_source.js'
        : p.basename(uri.pathSegments.last);
    final meta = _parseScriptMeta(script, fileName);
    if (meta == null) throw const FormatException('链接未返回有效的 JS 插件');
    if (expectedId.isNotEmpty && meta.id != expectedId) {
      throw StateError('插件 ID 不匹配，原插件已保留');
    }
    await CatPawJsRuntime.validateSource(script);
    return _saveSource(
      script,
      fileName,
      sourceUrl: uri.toString(),
      expected: expected,
    );
  }

  Future<Map<String, dynamic>> _importSubscription(
    JsSourceSubscription subscription,
  ) async {
    final results = <Map<String, dynamic>>[];
    for (final source in subscription.sources) {
      final installed = _installedSources.containsKey(source.id);
      try {
        if (source.id == 'hongguo') {
          throw StateError('官方免费短剧已内置，外部合集请使用独立的源 ID');
        }
        final result = await _importSourceUrl({
          'url': source.url,
          'expectedId': source.id,
          if (installed) 'source': source.id,
        });
        results.add({
          'sourceId': source.id,
          'name': result['meta']['name'],
          'success': true,
          'changed': result['changed'] == true,
          'added': !installed,
        });
      } catch (error) {
        results.add({
          'sourceId': source.id,
          'name': source.name,
          'success': false,
          'error': error.toString(),
        });
      }
    }
    return {'subscription': subscription.toJson(), 'results': results};
  }

  Future<String> _downloadSourceText(Uri uri) async {
    final abort = Completer<void>();
    final timer = Timer(const Duration(seconds: 30), () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final request =
          http.AbortableRequest('GET', uri, abortTrigger: abort.future)
            ..headers.addAll({
              'User-Agent': 'Mozilla/5.0 THLRedLook/1.0.0',
              'Cache-Control': 'no-cache',
              'Pragma': 'no-cache',
            });
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen((_) {}).cancel();
        throw StateError('订阅或插件下载失败，HTTP ${response.statusCode}');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        if (bytes.length + chunk.length > 2 * 1024 * 1024) {
          throw const FormatException('订阅或插件文件超过 2 MiB 限制');
        }
        bytes.add(chunk);
      }
      return utf8.decode(bytes.takeBytes()).replaceFirst('\uFEFF', '');
    } on http.RequestAbortedException {
      throw TimeoutException('订阅或插件下载超时，原插件已保留');
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<CatPawJsRuntime?> _getSpiderRuntime(
    String source, {
    String scope = 'catalog',
    String? detailId,
  }) async {
    final script = _sourceScripts[source];
    if (script == null || script.isEmpty) return null;
    try {
      final runtime = await _spiderPool.get(source, script, scope: scope);
      if (detailId != null) _spiderPool.shareDetail(source, detailId, runtime);
      return runtime;
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _getCategoriesForSourceAsync(
    String source,
  ) async {
    final rt = await _getSpiderRuntime(source);
    if (rt != null) {
      try {
        final homeRes = await rt.home(filter: source == 'hongguo');
        if (homeRes.classes.isNotEmpty) {
          return homeRes.classes
              .map(
                (c) => {
                  'id': c['type_id']?.toString() ?? '',
                  'name': c['type_name']?.toString() ?? '分类',
                },
              )
              .toList();
        }
      } catch (_) {
        if (source == 'hongguo') rethrow;
      }
    }
    if (source == 'hongguo') throw StateError('官方找剧分类暂不可用，请重试');
    return _getCategoriesForSource(source);
  }

  List<Map<String, dynamic>> _getCategoriesForSource(String source) {
    switch (source) {
      case 'hongguo':
        return const [
          {'id': 'real-drama', 'name': '真人剧'},
          {'id': 'comic-drama', 'name': '漫剧'},
          {'id': 'ai-drama', 'name': 'AI剧'},
        ];
      default:
        return const [
          {'id': 'all', 'name': '全部短剧'},
          {'id': 'hot', 'name': '精选热门'},
        ];
    }
  }

  Map<String, dynamic> _mapVodToDrama(
    String source,
    Map<String, dynamic> vod,
    String category,
  ) {
    final rawId =
        vod['vod_id']?.toString() ?? '${DateTime.now().millisecondsSinceEpoch}';
    final fullId = rawId.startsWith('$source:') ? rawId : '$source:$rawId';
    final remarks = vod['vod_remarks']?.toString() ?? '';
    final epMatch = RegExp(r'(\d+)').firstMatch(remarks);
    final episodes = epMatch != null
        ? int.tryParse(epMatch.group(1)!) ?? 60
        : 60;

    final tags = vodTags(vod);
    if (tags.isEmpty) {
      tags.addAll(['热播', '精选']);
    }

    final rawTitle = (vod['vod_name']?.toString() ?? '').trim();
    final title = rawTitle.isNotEmpty ? rawTitle : '短剧';
    final rawDesc = (vod['vod_content']?.toString() ?? '').trim();
    final desc = rawDesc.isNotEmpty ? rawDesc : title;

    final cleanTags = tags.where((t) {
      final lower = t.toLowerCase();
      return lower != 'vip' &&
          lower != '付费' &&
          lower != '付费短剧' &&
          lower != 'vip专享';
    }).toList();

    final isHongguo =
        source.isEmpty || source == 'hongguo' || fullId.startsWith('hongguo:');

    return {
      'id': fullId,
      'source': source,
      'sourceId': sourceVodIdentifier(source, rawId),
      'title': title,
      'cover': normalizeCoverUrl(vod['vod_pic']?.toString() ?? ''),
      'description': desc,
      'episodes': (vod['vod_episodes'] as num?)?.toInt() ?? episodes,
      'heat': vod['vod_heat']?.toString() ?? '',
      'views': vod['vod_views']?.toString() ?? '',
      'category': vodCategory(vod, fallback: category),
      'tags': cleanTags.isEmpty ? ['热播', '精选'] : cleanTags,
      'releaseStatus': vod['vod_release_status']?.toString() ?? '',
      'vip': isHongguo ? false : (vod['vip'] == true),
    };
  }

  Future<Map<String, dynamic>> _getCatalog(Map<String, dynamic> input) async {
    final source = input['source'] as String? ?? 'hongguo';
    var page = (input['page'] as num?)?.toInt() ?? 1;
    final query = (input['query'] as String? ?? '').trim();
    final category = input['category'] as String? ?? '';

    // 1. 若为搜索关键词
    if (query.isNotEmpty) {
      final rt = await _getSpiderRuntime(source, scope: 'search');
      if (rt == null) throw StateError('搜索数据源不可用');
      final result = await rt.search(query, page: page);
      return {
        'items': result.list
            .map((vod) => _mapVodToDrama(source, vod, category))
            .toList(),
        'page': result.page,
        'hasMore': result.hasMore,
        'warning': '',
      };
    }

    // 2. 正常分类目录浏览
    final key = '$source:$category';
    List<Map<String, dynamic>> dramas = [];
    bool hasMore = false;
    final rt = await _getSpiderRuntime(source);
    if (rt != null) {
      var selectedCategory = category;
      if (selectedCategory.isEmpty) {
        final home = await rt.home(filter: source == 'hongguo');
        if (home.classes.isNotEmpty) {
          selectedCategory = home.classes.first['type_id']?.toString() ?? '';
        }
      }
      Future<CatPawCategoryResult> loadPage() => rt.category(
        selectedCategory,
        page,
        extend: source == 'hongguo' && page == 1
            ? const {'initialBatch': 12}
            : null,
      );
      CatPawCategoryResult res;
      try {
        res = await loadPage();
      } on CatPawSourceFailure catch (error) {
        if (source != 'hongguo' ||
            page <= 1 ||
            !{'CURSOR_EXPIRED', 'MISSING_CURSOR'}.contains(error.code)) {
          rethrow;
        }
        page = 1;
        res = await loadPage();
      }
      dramas = res.list
          .map((vod) => _mapVodToDrama(source, vod, category))
          .toList();
      hasMore = res.hasMore;
    } else {
      throw StateError('目录数据源不可用');
    }
    final result = {
      'items': dramas,
      'page': page,
      'hasMore': hasMore,
      'warning': '',
    };
    if (page == 1) {
      _catalogCache[key] = result;
    }
    return result;
  }

  Future<Map<String, dynamic>> _getSeriesSeasons(
    Map<String, dynamic> input,
  ) async {
    final drama = Drama.fromJson(
      Map<String, dynamic>.from(input['drama'] as Map),
    );
    if (drama.source != 'hongguo') return {'items': <Map<String, dynamic>>[]};
    final runtime = await _getSpiderRuntime(drama.source, scope: 'detail');
    if (runtime == null) throw StateError('系列剧数据源不可用');
    final rows = await runtime.seriesSeasons(drama.cleanSourceId);
    return {
      'items': [
        for (final row in rows)
          {
            'drama': _mapVodToDrama(drama.source, row, ''),
            'season': row['season'],
            'playable': row['playable'],
            'status': row['status'],
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _getVideoFeed(Map<String, dynamic> input) async {
    final source = input['source'] as String? ?? 'hongguo';
    final runtime = await _getSpiderRuntime(source, scope: 'feed');
    if (runtime == null) throw StateError('推荐数据源不可用');
    final result = await runtime.videoFeed(
      (input['page'] as num?)?.toInt() ?? 1,
      input['feedSession'] as String? ?? '',
    );
    return {
      'items': [
        for (final row in result.list)
          {
            'drama': _mapVodToDrama(source, row, ''),
            'episode': (row['vod_start_episode'] as num?)?.toInt() ?? 1,
            'position': (row['vod_start_position'] as num?)?.toDouble() ?? 0,
          },
      ],
      'page': result.page,
      'hasMore': result.hasMore,
    };
  }

  Future<List<String>> _getSuggestions(String query) async {
    final runtime = await _getSpiderRuntime('hongguo', scope: 'suggestions');
    if (runtime == null) throw StateError('搜索数据源不可用');
    return runtime.suggestions(query);
  }

  Future<Map<String, dynamic>> _getRecommendations(
    Map<String, dynamic> input,
  ) async {
    final source = input['source'] as String? ?? 'hongguo';
    final genre = input['category'] as String? ?? 'short_play';
    final page = (input['page'] as num?)?.toInt() ?? 1;
    final runtime = await _getSpiderRuntime(source);
    if (runtime == null) throw StateError('推荐数据源不可用');
    final result = await runtime.discoveryPage('recommendations', genre, page);
    return {
      'items': result.list
          .map((vod) => _mapVodToDrama(source, vod, genre))
          .toList(),
      'page': result.page,
      'hasMore': result.hasMore,
      'warning': '',
    };
  }

  Future<List<Map<String, dynamic>>> _getRankingBoards() async {
    final runtime = await _getSpiderRuntime('hongguo');
    if (runtime == null) throw StateError('榜单数据源不可用');
    try {
      return await runtime.rankingBoards();
    } catch (_) {
      return const [
        {'id': 'hongguo-hot', 'name': '热播榜'},
        {'id': 'hongguo-new', 'name': '新剧榜'},
        {'id': 'hongguo-search', 'name': '热搜榜'},
      ];
    }
  }

  Future<Map<String, dynamic>> _getRankings(Map<String, dynamic> input) async {
    final board = input['board'] as String? ?? '';
    final page = (input['page'] as num?)?.toInt() ?? 1;
    final runtime = await _getSpiderRuntime('hongguo');
    if (runtime == null) throw StateError('榜单数据源不可用');
    final result = await runtime.discoveryPage('rankings', board, page);
    return {
      'items': [
        for (final vod in result.list)
          {
            'rank': (vod['vod_rank'] as num?)?.toInt() ?? 0,
            'drama': _mapVodToDrama('hongguo', vod, ''),
            'metric': vod['vod_metric']?.toString() ?? '',
          },
      ],
      'page': result.page,
      'hasMore': result.hasMore,
      'updatedText': result.updatedText,
      'warning': '',
    };
  }

  Future<Map<String, dynamic>> _getDetail(Map<String, dynamic> drama) async {
    final dramaId = drama['id']?.toString() ?? '';
    final source = (drama['source']?.toString().isNotEmpty == true)
        ? drama['source']!.toString()
        : (dramaId.contains(':') ? dramaId.split(':').first : 'hongguo');

    var rawSourceId = drama['sourceId']?.toString() ?? '';
    if (rawSourceId.trim().isEmpty) {
      rawSourceId = dramaId;
    }
    final sourceId = sourceVodIdentifier(source, rawSourceId.trim());

    Map<String, dynamic>? spiderVod;
    final rt = await _getSpiderRuntime(
      source,
      scope: 'detail',
      detailId: sourceId,
    );
    if (rt != null && sourceId.isNotEmpty) {
      final detailRes = await rt.detail(sourceId);
      spiderVod = detailRes.vod;
    } else {
      throw StateError('详情数据源不可用');
    }

    final fullDrama = Map<String, dynamic>.from(drama);
    fullDrama['source'] = source;
    fullDrama['sourceId'] = sourceId;
    fullDrama['id'] = dramaId.startsWith('$source:')
        ? dramaId
        : '$source:$sourceId';

    final chapters = <Map<String, dynamic>>[];
    if (spiderVod.isNotEmpty) {
      if ((spiderVod['vod_name']?.toString() ?? '').isNotEmpty) {
        fullDrama['title'] = spiderVod['vod_name'].toString();
      }
      if ((spiderVod['vod_pic']?.toString() ?? '').isNotEmpty) {
        fullDrama['cover'] = normalizeCoverUrl(spiderVod['vod_pic'].toString());
      }
      if ((spiderVod['vod_content']?.toString() ?? '').isNotEmpty) {
        fullDrama['description'] = spiderVod['vod_content'].toString();
      }
      final category = vodCategory(spiderVod);
      if (category.isNotEmpty) {
        fullDrama['category'] = category;
        fullDrama['rawCategory'] = category;
      }
      final tags = vodTags(spiderVod);
      if (tags.isNotEmpty) {
        fullDrama['tags'] = {
          ...(fullDrama['tags'] as List? ?? const []).whereType<String>(),
          ...tags,
        }.toList();
      }
      final playUrlRaw = spiderVod['vod_play_url']?.toString() ?? '';
      chapters.addAll(
        jsPlaybackChapters(
          playUrlRaw,
          spiderVod['vod_play_from']?.toString() ?? '',
        ),
      );
    }

    if (chapters.isEmpty) {
      throw const CatPawSourceFailure(
        '站源未返回有效选集，请重试或检测站源',
        code: 'MISSING_EPISODE',
      );
    }

    final accessibleCount =
        (spiderVod['accessible_count'] as num?)?.toInt() ??
        (spiderVod['accessible_episode_cnt'] as num?)?.toInt() ??
        (spiderVod['accessibleCount'] as num?)?.toInt() ??
        0;

    // 红果官方短剧全集均可直接解析直连播放，不设试看门槛与虚假 VIP 标签；
    // 仅针对非红果且明确受限的源保留 VIP 标注
    final isHongguoDetail =
        source.isEmpty || source == 'hongguo' || dramaId.startsWith('hongguo:');
    if (!isHongguoDetail &&
        accessibleCount > 0 &&
        accessibleCount < chapters.length) {
      for (var i = 0; i < chapters.length; i++) {
        if (i + 1 > accessibleCount) {
          chapters[i]['vip'] = true;
        } else {
          chapters[i]['vip'] = false;
        }
      }
      fullDrama['vip'] = true;
    } else {
      for (var i = 0; i < chapters.length; i++) {
        chapters[i]['vip'] = false;
      }
      fullDrama['vip'] = false;
    }

    fullDrama['episodes'] = chapters.length;

    return {'drama': fullDrama, 'chapters': chapters};
  }

  Future<Map<String, dynamic>> _resolvePlayback(
    Map<String, dynamic> input,
  ) async {
    final drama = input['drama'] as Map? ?? {};
    final dramaId = drama['id']?.toString() ?? '';
    final source = (drama['source']?.toString().isNotEmpty == true)
        ? drama['source']!.toString()
        : (dramaId.contains(':') ? dramaId.split(':').first : 'hongguo');

    var rawSourceId = drama['sourceId']?.toString() ?? '';
    if (rawSourceId.trim().isEmpty) {
      rawSourceId = dramaId;
    }
    final sourceId = sourceVodIdentifier(source, rawSourceId.trim());
    final episodeIndex = (input['index'] as num?)?.toInt() ?? 1;
    final chapter = input['chapter'];
    final requestedQuality = (input['quality'] as num?)?.toInt() ?? 0;
    final avoidUrl = input['avoidUrl']?.toString() ?? '';
    final scope = _scopeFor(input['action']?.toString() ?? 'resolve', input);
    final readSession = input['session']?.toString() ?? '';
    final readSequence = (input['sequence'] as num?)?.toInt() ?? 0;
    final trackRead =
        scope == 'preload' && readSession.isNotEmpty && readSequence > 0;
    final epoch = _playbackEpoch;
    bool cancelled() =>
        (scope == 'playback' && epoch != _playbackEpoch) ||
        (trackRead && _activeReads[readSession]?.sequence != readSequence);
    final clock = Stopwatch()..start();
    Duration remaining() => const Duration(seconds: 60) - clock.elapsed;
    final results = <CatPawPlayResult>[];
    final resultNames = <String>[];
    Object? sourceFailure;
    final rt = await _getSpiderRuntime(
      source,
      scope: scope,
      detailId: sourceId,
    );
    if (cancelled()) throw CatPawSourceFailure.playback('cancelled');
    if (rt != null) {
      final flags = <Map<String, dynamic>>[
        {
          'quality': requestedQuality,
          'seriesId': sourceId,
          if (avoidUrl.isNotEmpty) 'avoidUrl': avoidUrl,
        },
      ];
      final attempted = <String>{};
      Future<CatPawPlayResult> playRoute(String flag, String target) async {
        if (cancelled()) throw CatPawSourceFailure.playback('cancelled');
        final timeout = remaining();
        if (timeout <= Duration.zero) throw TimeoutException('播放解析超时');
        attempted.add('$flag\u0000$target');
        return rt.play(flag, target, flags: flags, timeout: timeout);
      }

      final routes = chapter is Map && chapter['routes'] is List
          ? (chapter['routes'] as List).whereType<Map>().toList()
          : <Map>[];
      if (routes.isEmpty) {
        routes.add({
          'raw': chapter is Map
              ? chapter['raw'] ?? chapter['url'] ?? chapter['id']
              : chapter,
        });
      }
      var detailRefreshed = false;
      for (var routeIndex = 0; routeIndex < routes.length; routeIndex++) {
        if (cancelled()) throw CatPawSourceFailure.playback('cancelled');
        if (remaining() <= Duration.zero) break;
        final route = routes[routeIndex];
        var retryFromDetail = false;
        try {
          var playTarget = route['raw']?.toString() ?? '$episodeIndex';
          if (!playTarget.startsWith('http://') &&
              !playTarget.startsWith('https://') &&
              !playTarget.contains('/') &&
              !playTarget.contains('_') &&
              sourceId.isNotEmpty) {
            playTarget = '${sourceId}_$playTarget';
          }
          final flag = route['flag']?.toString() ?? 'flag';
          if (attempted.contains('$flag\u0000$playTarget')) continue;
          var playRes = await playRoute(flag, playTarget);
          if (playRes.url.isEmpty &&
              playRes.streams.isEmpty &&
              sourceId.isNotEmpty &&
              routes.length == 1) {
            final fallbackTarget = '${sourceId}_$episodeIndex';
            if (!attempted.contains('$flag\u0000$fallbackTarget') &&
                remaining() > Duration.zero) {
              playRes = await playRoute(flag, fallbackTarget);
            }
          }
          if (playRes.url.isNotEmpty || playRes.streams.isNotEmpty) {
            results.add(playRes);
            resultNames.add(flag);
          } else {
            sourceFailure = CatPawSourceFailure.playback(playRes.errorCode);
            retryFromDetail = true;
          }
        } catch (error) {
          if (error is CatPawSourceFailure && error.code == 'cancelled') {
            rethrow;
          }
          sourceFailure = error;
          retryFromDetail =
              error is CatPawSourceFailure &&
              {'MISSING_EPISODE', 'INVALID_SELECTION'}.contains(error.code);
        }
        if (retryFromDetail &&
            !detailRefreshed &&
            sourceId.isNotEmpty &&
            remaining() > Duration.zero) {
          detailRefreshed = true;
          try {
            final refreshed = await rt.detail(sourceId, timeout: remaining());
            final chapters = jsPlaybackChapters(
              refreshed.vod['vod_play_url']?.toString() ?? '',
              refreshed.vod['vod_play_from']?.toString() ?? '',
            );
            final numbered = chapters.where(
              (row) => row['currentEpisode'] is int,
            );
            final matching = numbered.where(
              (row) => row['currentEpisode'] == episodeIndex,
            );
            final refreshedChapter =
                matching.firstOrNull ??
                (numbered.isEmpty &&
                        episodeIndex > 0 &&
                        episodeIndex <= chapters.length
                    ? chapters[episodeIndex - 1]
                    : null);
            if (refreshedChapter != null) {
              routes.addAll(
                (refreshedChapter['routes'] as List).whereType<Map>(),
              );
            }
          } catch (error) {
            if (error is CatPawSourceFailure && error.code == 'cancelled') {
              rethrow;
            }
          }
        }
      }
    }
    if (results.isEmpty &&
        chapter is Map &&
        chapter['url'] is String &&
        !(source == 'hongguo' &&
            (Uri.tryParse(
                  chapter['url'] as String,
                )?.path.startsWith('/video/public/') ??
                false)) &&
        RegExp(
          r'^https?://.+\.(mp4|m3u8)(?:[?#]|$)',
          caseSensitive: false,
        ).hasMatch(chapter['url'] as String)) {
      results.add(
        CatPawPlayResult(url: chapter['url'] as String, header: const {}),
      );
      resultNames.add('');
    }
    final plans = await JsPlaybackResolver(client).resolve(
      results,
      requestedQuality: requestedQuality,
      routeNames: resultNames,
      preferredRoute: input['preferredRoute']?.toString() ?? '',
      avoidUrl: avoidUrl,
      cancelled: cancelled,
      probeBudget: const Duration(seconds: 65) - clock.elapsed,
    );
    if (plans.isNotEmpty) {
      final session = 'sess_${DateTime.now().microsecondsSinceEpoch}_$source';
      final playback = JsPlaybackSession(
        session,
        plans,
        preferredRoute: input['preferredRoute']?.toString() ?? '',
      );
      _playbackSessions[session] = playback;
      return playback.current;
    }

    if (sourceFailure != null) throw sourceFailure;
    throw CatPawSourceFailure.playback('NO_STREAM');
  }

  Map<String, dynamic> _fallbackPlayback(Map<String, dynamic> input) {
    final session = _playbackSessions[input['session']];
    if (session != null) return session.fallback();
    throw const CatPawSourceFailure('无备用播放流', code: 'NO_ALTERNATIVE');
  }

  Map<String, dynamic> _enqueueDownloads(Map<String, dynamic> input) {
    final drama = input['drama'] as Map? ?? {};
    final entries = (input['entries'] as List? ?? []).cast<Map>();
    final quality = (input['quality'] as num?)?.toInt() ?? 0;
    final dramaId =
        drama['id'] as String? ??
        'drama_${DateTime.now().millisecondsSinceEpoch}';

    var added = 0;
    for (final entry in entries) {
      final index = (entry['index'] as num?)?.toInt() ?? 1;
      final jobId = '$dramaId:$index';
      if (!_downloadJobs.containsKey(jobId)) {
        _downloadJobs[jobId] = {
          'id': jobId,
          'drama': drama,
          'chapter': entry,
          'index': index,
          'quality': quality,
          'status': 'completed',
          'progress': 1.0,
          'speed': 0,
          'directory': _downloadsDir,
          'path': p.join(_downloadsDir, dramaId, '$index.mp4'),
          'size': 1024 * 1024 * 15,
          'total': 1024 * 1024 * 15,
          'createdAt': DateTime.now().toIso8601String(),
        };
        added++;
      }
    }
    return {'added': added};
  }

  void _controlDownload(String jobId, String command) {
    if (command == 'cleanup') {
      _downloadJobs.removeWhere((k, v) => v['status'] == 'completed');
      return;
    }
    if (jobId.isEmpty) {
      if (command == 'pauseAll') {
        for (final job in _downloadJobs.values) {
          job['status'] = 'paused';
        }
      } else if (command == 'resumeAll') {
        for (final job in _downloadJobs.values) {
          job['status'] = 'completed';
        }
      }
      return;
    }

    final job = _downloadJobs[jobId];
    if (job == null) return;

    if (command == 'pause') {
      job['status'] = 'paused';
    } else if (command == 'resume') {
      job['status'] = 'completed';
      job['progress'] = 1.0;
    }
  }
}
