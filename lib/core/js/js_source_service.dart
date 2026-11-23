import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:THLRedLook/core/bridge/core_bridge.dart';
import 'package:THLRedLook/core/js/catpaw_js_runtime.dart';
import 'package:THLRedLook/core/js/js_source_models.dart';
import 'package:THLRedLook/core/js/js_source_presets.dart';
import 'package:THLRedLook/core/js/js_source_subscription.dart';
import 'package:THLRedLook/core/diagnostics/source_diagnostics.dart';

class JsSourceService extends ChangeNotifier {
  JsSourceService(this._repository, [this._preferences]) {
    current = this;
  }

  static JsSourceService? current;
  static const _activeSourceKey = 'active_js_source_id';
  final AppRepository _repository;
  SharedPreferences? _preferences;
  static const String _subscriptionsKey = 'js_source_subscriptions_v1';
  List<JsSourceMeta> _sources = [];
  List<JsSourceSubscription> _subscriptions = [];
  JsSubscriptionImportResult? _lastSubscriptionImport;
  bool _subscriptionsLoaded = false;
  String _activeSourceId = '';
  bool _initialized = false;
  bool _loading = false;
  bool _updatingAll = false;
  String _updatingSourceId = '';
  String _updatingSubscriptionUrl = '';
  String _lastError = '';
  bool _disposed = false;
  int _pendingOperations = 0;
  Future<void>? _initializing;

  List<JsSourceMeta> get sources => List.unmodifiable(_sources);
  List<JsSourceSubscription> get subscriptions =>
      List.unmodifiable(_subscriptions);
  JsSubscriptionImportResult? get lastSubscriptionImport =>
      _lastSubscriptionImport;
  String get activeSourceId => _activeSourceId;
  bool get initialized => _initialized;
  bool get loading => _loading || _updatingAll || _pendingOperations > 0;
  bool get updatingAll => _updatingAll;
  String get updatingSourceId => _updatingSourceId;
  String get updatingSubscriptionUrl => _updatingSubscriptionUrl;
  String get lastError => _lastError;
  JsSourceMeta? get activeSource =>
      _sources.where((source) => source.id == _activeSourceId).firstOrNull ??
      _sources.firstOrNull;
  bool get hasSubscriptions =>
      _subscriptions.isNotEmpty ||
      _sources.any((source) => source.sourceUrl.isNotEmpty);

  bool isBuiltinSource(String id) =>
      kPresetJsSources.any((source) => source.id == id);

  void _notifyChange() {
    if (!_disposed) notifyListeners();
  }

  Future<void> loadSubscriptions() async {
    if (_subscriptionsLoaded) return;
    _preferences ??= await SharedPreferences.getInstance();
    final stored = _preferences?.getString(_subscriptionsKey);
    if (stored != null) {
      final items = jsonDecode(stored) as List;
      _subscriptions = items.map((item) {
        final json = Map<String, dynamic>.from(item as Map);
        return JsSourceSubscription.fromJson(json, json['url'] as String);
      }).toList();
    }
    _subscriptionsLoaded = true;
    _notifyChange();
  }

  Future<void> _saveSubscriptions(
    List<JsSourceSubscription> subscriptions,
  ) async {
    _preferences ??= await SharedPreferences.getInstance();
    final saved = await _preferences!.setString(
      _subscriptionsKey,
      jsonEncode(subscriptions.map((item) => item.toJson()).toList()),
    );
    if (!saved) throw StateError('合集订阅地址保存失败，请重新导入');
    _subscriptions = subscriptions;
  }

  Future<void> _rememberSubscription(JsSourceSubscription subscription) =>
      _saveSubscriptions([
        for (final item in _subscriptions)
          item.url == subscription.url ? subscription : item,
        if (!_subscriptions.any((item) => item.url == subscription.url))
          subscription,
      ]);

  Future<T> _withLoading<T>(Future<T> Function() operation) async {
    if (_disposed) throw StateError('数据源管理已关闭');
    _pendingOperations++;
    _notifyChange();
    try {
      return await operation();
    } finally {
      _pendingOperations--;
      _notifyChange();
    }
  }

  Future<void> initialize() {
    if (_initialized) return Future.value();
    return _initializing ??= _withLoading(() async {
      unawaited(CatPawJsRuntime.preloadDeviceSession());
      await _repository.jsSourceScan();
      _sources = await _repository.jsSourceList();
      for (final preset in kPresetJsSources) {
        if (_sources.any(
          (source) => source.id == preset.id && source.sourceUrl.isNotEmpty,
        )) {
          continue;
        }
        final script = await preset.loadScript();
        if (_sources.any(
          (source) =>
              source.id == preset.id &&
              JsSourceMeta.isVersionNewer(
                source.version,
                JsSourceMeta.scriptVersion(script),
              ),
        )) {
          continue;
        }
        if (!await _repository.jsSourceSaveAndLoad(script, preset.fileName)) {
          throw StateError('内置数据源导入失败，请重试');
        }
      }
      _sources = await _repository.jsSourceList();
      _preferences ??= await SharedPreferences.getInstance();
      var saved = _preferences?.getString(_activeSourceKey) ?? '';
      if (!_sources.any((source) => source.id == saved)) {
        saved = _sources.firstOrNull?.id ?? '';
      }
      if (saved.isNotEmpty && !await _repository.jsSourceSetActive(saved)) {
        throw StateError('数据源启用失败，请重试');
      }
      _activeSourceId = saved;
      await loadSubscriptions();
      _initialized = true;
    }).whenComplete(() => _initializing = null);
  }

  Future<bool> switchSource(String sourceId) async {
    if (_activeSourceId == sourceId) return true;
    if (!_sources.any((source) => source.id == sourceId)) return false;
    return _withLoading(() async {
      final ok = await _repository.jsSourceSetActive(sourceId);
      if (ok) {
        _activeSourceId = sourceId;
        _preferences ??= await SharedPreferences.getInstance();
        await _preferences?.setString(_activeSourceKey, sourceId);
      }
      return ok;
    });
  }

  Future<bool> importScript(String script, String fileName) {
    if (loading) return Future.value(false);
    return _withLoading(() async {
      final ok = await _repository.jsSourceSaveAndLoad(script, fileName);
      if (ok) await _syncImportedSources();
      return ok;
    });
  }

  Future<bool> importFromUrl(String url) async {
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty || loading) return false;

    _loading = true;
    _lastError = '';
    _lastSubscriptionImport = null;
    _notifyChange();

    try {
      await loadSubscriptions();
      final result = await _repository.jsSourceImportFromUrl(cleanUrl);
      await _syncImportedSources();
      if (result['subscription'] is Map) {
        final imported = JsSubscriptionImportResult.fromJson(result);
        await _rememberSubscription(imported.subscription);
        _lastSubscriptionImport = imported;
      }
      return true;
    } catch (error) {
      _lastError = SourceDiagnostics.analyzeError(error).message;
      return false;
    } finally {
      _loading = false;
      _notifyChange();
    }
  }

  Future<void> _syncImportedSources() async {
    _sources = await _repository.jsSourceList();
    if (_sources.isNotEmpty &&
        !_sources.any((source) => source.id == _activeSourceId)) {
      final id = _sources.first.id;
      if (await _repository.jsSourceSetActive(id)) {
        _activeSourceId = id;
        await _preferences?.setString(_activeSourceKey, id);
      }
    }
  }

  Future<JsSubscriptionImportResult> _refreshSubscription(
    JsSourceSubscription subscription,
  ) async {
    _updatingSubscriptionUrl = subscription.url;
    _notifyChange();
    final result = JsSubscriptionImportResult.fromJson(
      await _repository.jsSourceImportSubscription(subscription.url),
    );
    await _syncImportedSources();
    await _rememberSubscription(result.subscription);
    return result;
  }

  Future<JsSubscriptionImportResult?> refreshSubscription(
    JsSourceSubscription subscription,
  ) async {
    if (loading) return null;
    _loading = true;
    _lastError = '';
    _notifyChange();
    try {
      await loadSubscriptions();
      return await _refreshSubscription(subscription);
    } catch (error) {
      _lastError = SourceDiagnostics.analyzeError(error).message;
      return null;
    } finally {
      _loading = false;
      _updatingSubscriptionUrl = '';
      _notifyChange();
    }
  }

  Future<bool> removeSubscription(String url) async {
    if (loading) return false;
    _loading = true;
    _lastError = '';
    _notifyChange();
    try {
      await loadSubscriptions();
      await _saveSubscriptions([
        for (final subscription in _subscriptions)
          if (subscription.url != url) subscription,
      ]);
      return true;
    } catch (error) {
      _lastError = SourceDiagnostics.analyzeError(error).message;
      return false;
    } finally {
      _loading = false;
      _notifyChange();
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
    _notifyChange();
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
      _notifyChange();
    }
  }

  Future<List<JsSourceUpdateResult>> updateAll() async {
    if (loading) return [];
    _updatingAll = true;
    _lastError = '';
    _notifyChange();
    try {
      await loadSubscriptions();
      final results = <JsSourceUpdateResult>[];
      final groupedIds = <String>{};
      for (final subscription in [..._subscriptions]) {
        groupedIds.addAll(subscription.sources.map((source) => source.id));
        try {
          final result = await _refreshSubscription(subscription);
          groupedIds.addAll(
            result.subscription.sources.map((source) => source.id),
          );
          results.addAll(result.results);
        } catch (error) {
          results.add(
            JsSourceUpdateResult(
              sourceId: '',
              name: subscription.name,
              success: false,
              error: SourceDiagnostics.analyzeError(error).message,
            ),
          );
        }
      }
      _updatingSubscriptionUrl = '';
      final standaloneSources = _sources
          .where(
            (source) =>
                source.sourceUrl.isNotEmpty && !groupedIds.contains(source.id),
          )
          .toList();
      for (final source in standaloneSources) {
        results.add(await updateSource(source.id));
      }
      return results;
    } catch (error) {
      _lastError = SourceDiagnostics.analyzeError(error).message;
      return [
        JsSourceUpdateResult(
          sourceId: '',
          name: '网络订阅',
          success: false,
          error: _lastError,
        ),
      ];
    } finally {
      _updatingAll = false;
      _updatingSubscriptionUrl = '';
      _notifyChange();
    }
  }

  Future<bool> removeSource(String sourceId) async {
    if (loading || isBuiltinSource(sourceId)) return false;
    return _withLoading(() async {
      final ok = await _repository.jsSourceRemove(sourceId);
      if (ok) {
        await _syncImportedSources();
        if (_sources.isEmpty) {
          _activeSourceId = '';
          await _preferences?.remove(_activeSourceKey);
        }
      }
      return ok;
    });
  }

  Future<void> reload() => _withLoading(() async {
    await _repository.jsSourceScan();
    _sources = await _repository.jsSourceList();
    _activeSourceId = await _repository.jsSourceGetActive();
    await loadSubscriptions();
  });

  Future<void> clearAll() async {
    if (loading) return;
    _loading = true;
    _notifyChange();

    try {
      await loadSubscriptions();
      for (final source in [..._sources]) {
        if (!isBuiltinSource(source.id)) {
          final removed = await _repository.jsSourceRemove(source.id);
          if (!removed) throw StateError('删除数据源 ${source.name} 失败');
        }
      }
      for (final preset in kPresetJsSources) {
        if (_sources.any((source) => source.id == preset.id)) continue;
        final imported = await _repository.jsSourceSaveAndLoad(
          await preset.loadScript(),
          preset.fileName,
        );
        if (!imported) throw StateError('内置源 ${preset.name} 加载失败');
      }
      await _syncImportedSources();
      await _saveSubscriptions([]);
    } finally {
      _loading = false;
      _notifyChange();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (identical(current, this)) current = null;
    super.dispose();
  }
}
