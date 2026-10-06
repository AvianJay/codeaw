import 'dart:async';

import 'package:flutter/foundation.dart';

import '../acp/jsonrpc.dart';
import 'bridge_client.dart';
import 'models.dart';
import 'history_cache.dart';

/// The session list across all agents, kept fresh by `_codeaw/activity` notifications.
class SessionsModel extends ChangeNotifier {
  SessionsModel(this.client, {HistoryCache? cache})
    : cache = cache ?? HistoryCache(client.host) {
    _activitySub = client.activity.listen(_onActivity);
    _connSub = client.connected.listen((_) => unawaited(refresh()));
    unawaited(restore());
  }

  final BridgeClient client;
  final HistoryCache cache;
  static const _cacheId = '__session_list__';
  Timer? _cacheTimer;
  bool _cacheReady = false;
  int _revision = 0;
  List<SessionSummary> sessions = [];
  final _removed = <String>{};
  final _deleting = <String>{};
  bool isDeleting(String id) => _deleting.contains(id);
  bool loading = false;
  String? error;
  List<String> agentErrors = [];
  String? _nextCursor;
  bool get hasMore => _nextCursor != null;
  StreamSubscription<Map<String, dynamic>>? _activitySub;
  StreamSubscription<void>? _connSub;
  Timer? _refreshDebounce;
  bool _disposed = false;

  Future<void> restore() async {
    final revision = _revision;
    final saved = await cache.read(_cacheId);
    if (_disposed ||
        sessions.isNotEmpty ||
        saved == null ||
        revision != _revision) {
      return;
    }
    try {
      _removed.addAll((saved['removed'] as List? ?? const []).whereType<String>());
      sessions = (saved['sessions'] as List)
          .map(
            (s) => SessionSummary.fromJson(Map<String, dynamic>.from(s as Map)),
          )
          .where((s) => !_removed.contains(s.id))
          .toList();
      _cacheReady = true;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> persist() {
    _cacheTimer?.cancel();
    _cacheTimer = null;
    return !_cacheReady
        ? Future.value()
        : cache.write(_cacheId, {
            'removed': _removed.toList(),
            'sessions': [
              for (final s in sessions)
                {
                  'sessionId': s.id,
                  'cwd': s.cwd,
                  'title': s.title,
                  'updatedAt': s.updatedAt?.toIso8601String(),
                  '_meta': {
                    'codeaw': {
                      'agentId': s.agentId,
                      'state': s.state,
                      'pending': s.pending,
                      'queued': s.queued,
                      'known': s.known,
                      'projectless': s.projectless,
                      if (s.desktopSync) 'connection': 'desktop',
                    },
                  },
                },
            ],
          });
  }

  void discardPendingCache() {
    _cacheTimer?.cancel();
    _cacheTimer = null;
    _cacheReady = false;
    _revision++;
  }

  void _saveSoon() {
    _revision++;
    _cacheReady = true;
    _cacheTimer ??= Timer(const Duration(seconds: 2), () {
      _cacheTimer = null;
      unawaited(persist());
    });
  }

  Future<void> refresh() async {
    if (_disposed || !client.isOnline) return;
    loading = true;
    notifyListeners();
    try {
      final r =
          await client.request('session/list', {}) as Map<String, dynamic>;
      if (_disposed) return;
      sessions = _parse(r);
      _saveSoon();
      error = null;
    } on RpcError catch (e) {
      error = e.detail;
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> loadMore() async {
    final cursor = _nextCursor;
    if (_disposed || cursor == null || loading) return;
    loading = true;
    notifyListeners();
    try {
      final r =
          await client.request('session/list', {'cursor': cursor})
              as Map<String, dynamic>;
      if (_disposed) return;
      final more = _parse(r);
      final known = sessions.map((s) => s.id).toSet();
      sessions = [...sessions, ...more.where((s) => !known.contains(s.id))];
      _saveSoon();
    } on RpcError catch (e) {
      error = e.detail;
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  List<SessionSummary> _parse(Map<String, dynamic> r) {
    _nextCursor = r['nextCursor'] as String?;
    final errs =
        ((r['_meta'] as Map?)?['codeaw'] as Map?)?['errors'] as List? ??
        const [];
    agentErrors = [
      for (final e in errs.whereType<Map>())
        '${client.agent('${e['agentId']}')?.name ?? e['agentId']}：${e['message']}',
    ];
    return (r['sessions'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SessionSummary.fromJson)
        .where((s) => !_removed.contains(s.id))
        .toList();
  }

  Future<void> deleteSession(String id) async {
    if (!client.isOnline) throw StateError('請先連線到電腦，再刪除聊天');
    if (!_deleting.add(id)) return;
    notifyListeners();
    try {
      await client.request('session/delete', {'sessionId': id});
      if (_disposed) return;
      _remove(id);
      await cache.remove(id);
      await persist();
    } finally {
      _deleting.remove(id);
      if (!_disposed) notifyListeners();
    }
  }

  void _remove(String id) {
    _removed.add(id);
    sessions = sessions.where((s) => s.id != id).toList();
    _saveSoon();
  }

  SessionSummary? byId(String id) {
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  void _onActivity(Map<String, dynamic> a) {
    final id = a['sessionId'] as String?;
    if (id == null) return;
    if (a['deleted'] == true) {
      _remove(id);
      unawaited(cache.remove(id));
      unawaited(persist());
      notifyListeners();
      return;
    }
    if (_removed.contains(id)) return;
    final s = byId(id);
    if (s == null) {
      // A session created elsewhere: pick it up on the next (debounced) list.
      _refreshDebounce?.cancel();
      _refreshDebounce = Timer(
        const Duration(seconds: 1),
        () => unawaited(refresh()),
      );
      return;
    }
    s.state = a['state'] as String? ?? s.state;
    s.pending = (a['pending'] as num?)?.toInt() ?? s.pending;
    s.queued = (a['queued'] as num?)?.toInt() ?? s.queued;
    if (a['title'] is String) s.title = a['title'] as String;
    final updated = DateTime.tryParse(a['updatedAt'] as String? ?? '');
    if (updated != null) s.updatedAt = updated;
    s.known = true;
    _saveSoon();
    sessions.sort(
      (x, y) =>
          (y.updatedAt ?? DateTime(0)).compareTo(x.updatedAt ?? DateTime(0)),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    if (_cacheTimer != null) unawaited(persist());
    _cacheTimer?.cancel();
    _disposed = true;
    _activitySub?.cancel();
    _connSub?.cancel();
    _refreshDebounce?.cancel();
    super.dispose();
  }
}
