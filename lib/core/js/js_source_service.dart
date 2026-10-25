import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:THLRedLook/core/bridge/core_bridge.dart';
import 'package:THLRedLook/core/js/catpaw_js_runtime.dart';
import 'package:THLRedLook/core/js/js_source_models.dart';
import 'package:THLRedLook/core/js/js_source_presets.dart';
import 'package:THLRedLook/core/diagnostics/source_diagnostics.dart';

class JsSourceService extends ChangeNotifier {
  JsSourceService(this._repository, [this._preferences]) {
    current = this;
  }

  static JsSourceService? current;
  final AppRepository _repository;
  SharedPreferences? _preferences;

  static const String _activeSourceKey = 'active_js_source_id';

  List<JsSourceMeta> _sources = [];
  String _activeSourceId = '';
  bool _initialized = false;
  bool _loading = false;
  bool _updatingAll = false;
  String _updatingSourceId = '';
  String _lastError = '';

  List<JsSourceMeta> get sources => List.unmodifiable(_sources);
  String get activeSourceId => _activeSourceId;
  bool get initialized => _initialized;
  bool get loading => _loading || _updatingAll;
  bool get updatingAll => _updatingAll;
  String get updatingSourceId => _updatingSourceId;
  String get lastError => _lastError;
  bool get hasSubscriptions =>
      _sources.any((source) => source.sourceUrl.isNotEmpty);

  JsSourceMeta? get activeSource {
    for (final src in _sources) {
      if (src.id == _activeSourceId) {
        return src;
      }
    }
    return _sources.isNotEmpty ? _sources.first : null;
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _loading = true;
    notifyListeners();

    try {
      unawaited(CatPawJsRuntime.preloadDeviceSession());
      // 扫描本地已导入的 sources 目录
      await _repository.jsSourceScan();

      // 3. 读取所有已加载的源列表
      _sources = await _repository.jsSourceList();

      for (final preset in kPresetJsSources) {
        if (_sources.any(
          (source) => source.id == preset.id && source.sourceUrl.isNotEmpty,
        )) {
          continue;
        }
        final script = await preset.loadScript();
        await _repository.jsSourceSaveAndLoad(script, preset.fileName);
      }
      _sources = await _repository.jsSourceList();

      // 4. 读取用户保存的活跃源偏好
      _preferences ??= await SharedPreferences.getInstance();
      var savedActiveId = _preferences?.getString(_activeSourceKey) ?? '';

      // 验证 savedActiveId 是否依然存在
      if (savedActiveId.isEmpty ||
          !_sources.any((s) => s.id == savedActiveId)) {
        if (_sources.isNotEmpty) {
          savedActiveId = _sources.first.id;
        }
      }

      if (savedActiveId.isNotEmpty) {
        await _repository.jsSourceSetActive(savedActiveId);
        _activeSourceId = savedActiveId;
      }
    } catch (e) {
      debugPrint('初始化 JsSourceService 异常: $e');
    } finally {
      _initialized = true;
      _loading = false;
      notifyListeners();
    }
  }

  Future<bool> switchSource(String sourceId) async {
    if (_activeSourceId == sourceId) return true;
    if (!_sources.any((s) => s.id == sourceId)) return false;

    _loading = true;
    notifyListeners();

    final ok = await _repository.jsSourceSetActive(sourceId);
    if (ok) {
      _activeSourceId = sourceId;
      try {
        _preferences ??= await SharedPreferences.getInstance();
        await _preferences?.setString(_activeSourceKey, sourceId);
      } catch (_) {}
    }

    _loading = false;
    notifyListeners();
    return ok;
  }

  Future<bool> importScript(String script, String fileName) async {
    _loading = true;
    notifyListeners();

    final ok = await _repository.jsSourceSaveAndLoad(script, fileName);
    if (ok) {
      _sources = await _repository.jsSourceList();
      if (_sources.isNotEmpty &&
          (_activeSourceId.isEmpty ||
              !_sources.any((s) => s.id == _activeSourceId))) {
        await switchSource(_sources.first.id);
      }
    }

    _loading = false;
    notifyListeners();
    return ok;
  }

  Future<bool> importFromUrl(String url) async {
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty || loading) return false;

    _loading = true;
    _lastError = '';
    notifyListeners();

    try {
      await _repository.jsSourceImportFromUrl(cleanUrl);
      _sources = await _repository.jsSourceList();
      if (!_sources.any((source) => source.id == _activeSourceId) &&
          _sources.isNotEmpty) {
        await switchSource(_sources.first.id);
      }
      return true;
    } catch (error) {
      _lastError = SourceDiagnostics.analyzeError(error).message;
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<JsSourceUpdateResult> updateSource(
    String sourceId, {
    String? url,
  }) async {
    final source = _sources.where((item) => item.id == sourceId).firstOrNull;
    final target = (url ?? source?.sourceUrl ?? '').trim();
    if (_loading || source == null || target.isEmpty) {
      return JsSourceUpdateResult(
        sourceId: sourceId,
        name: source?.name ?? sourceId,
        success: false,
        error: _loading ? '请等待当前操作完成' : '请先设置更新链接',
      );
    }
    _loading = true;
    _updatingSourceId = sourceId;
    _lastError = '';
    notifyListeners();
    try {
      final result = await _repository.jsSourceImportFromUrl(
        target,
        sourceId: sourceId,
      );
      _sources = await _repository.jsSourceList();
      return JsSourceUpdateResult(
        sourceId: sourceId,
        name: source.name,
        success: true,
        changed: result['changed'] == true,
      );
    } catch (error) {
      _lastError = SourceDiagnostics.analyzeError(error).message;
      return JsSourceUpdateResult(
        sourceId: sourceId,
        name: source.name,
        success: false,
        error: _lastError,
      );
    } finally {
      _loading = false;
      _updatingSourceId = '';
      notifyListeners();
    }
  }

  Future<List<JsSourceUpdateResult>> updateAll() async {
    if (loading) return [];
    final subscriptions = _sources
        .where((source) => source.sourceUrl.isNotEmpty)
        .toList();
    _updatingAll = true;
    notifyListeners();
    try {
      final results = <JsSourceUpdateResult>[];
      for (final source in subscriptions) {
        results.add(await updateSource(source.id));
      }
      return results;
    } finally {
      _updatingAll = false;
      notifyListeners();
    }
  }

  Future<bool> removeSource(String sourceId) async {
    if (_activeSourceId == sourceId) {
      final other = _sources.firstWhere(
        (s) => s.id != sourceId,
        orElse: () => const JsSourceMeta(id: '', name: ''),
      );
      if (other.id.isNotEmpty) {
        await switchSource(other.id);
      }
    }

    _loading = true;
    notifyListeners();

    final ok = await _repository.jsSourceRemove(sourceId);
    if (ok) {
      _sources = await _repository.jsSourceList();
      if (!_sources.any((s) => s.id == _activeSourceId)) {
        _activeSourceId = _sources.isNotEmpty ? _sources.first.id : '';
        try {
          _preferences ??= await SharedPreferences.getInstance();
          if (_activeSourceId.isNotEmpty) {
            await _preferences?.setString(_activeSourceKey, _activeSourceId);
          } else {
            await _preferences?.remove(_activeSourceKey);
          }
        } catch (_) {}
      }
    }

    _loading = false;
    notifyListeners();
    return ok;
  }

  Future<void> reload() async {
    _loading = true;
    notifyListeners();

    await _repository.jsSourceScan();
    _sources = await _repository.jsSourceList();
    _activeSourceId = await _repository.jsSourceGetActive();

    _loading = false;
    notifyListeners();
  }

  Future<void> clearAll() async {
    _loading = true;
    notifyListeners();

    await _repository.jsSourceClearAll();
    _sources = [];
    _activeSourceId = '';
    await _preferences?.remove(_activeSourceKey);

    _loading = false;
    notifyListeners();
  }
}
