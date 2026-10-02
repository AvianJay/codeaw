import 'dart:async';

import 'package:flutter/foundation.dart';

import '../acp/jsonrpc.dart';
import 'bridge_client.dart';
import 'models.dart';

/// The session list across all agents, kept fresh by `_codeaw/activity` notifications.
class SessionsModel extends ChangeNotifier {
  SessionsModel(this.client) {
    _activitySub = client.activity.listen(_onActivity);
    _connSub = client.connected.listen((_) => unawaited(refresh()));
  }

  final BridgeClient client;
  List<SessionSummary> sessions = [];
  bool loading = false;
  String? error;
  List<String> agentErrors = [];
  String? _nextCursor;
  bool get hasMore => _nextCursor != null;
  StreamSubscription<Map<String, dynamic>>? _activitySub;
  StreamSubscription<void>? _connSub;
  Timer? _refreshDebounce;
  bool _disposed = false;

  Future<void> refresh() async {
    if (_disposed || !client.isOnline) return;
    loading = true;
    notifyListeners();
    try {
      final r = await client.request('session/list', {}) as Map<String, dynamic>;
      if (_disposed) return;
      sessions = _parse(r);
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
      final r = await client.request('session/list', {'cursor': cursor}) as Map<String, dynamic>;
      if (_disposed) return;
      final more = _parse(r);
      final known = sessions.map((s) => s.id).toSet();
      sessions = [...sessions, ...more.where((s) => !known.contains(s.id))];
    } on RpcError catch (e) {
      error = e.detail;
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  List<SessionSummary> _parse(Map<String, dynamic> r) {
    _nextCursor = r['nextCursor'] as String?;
    final errs = ((r['_meta'] as Map?)?['codeaw'] as Map?)?['errors'] as List? ?? const [];
    agentErrors = [for (final e in errs.whereType<Map>()) '${client.agent('${e['agentId']}')?.name ?? e['agentId']}：${e['message']}'];
    return (r['sessions'] as List? ?? const []).whereType<Map<String, dynamic>>().map(SessionSummary.fromJson).toList();
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
      sessions = sessions.where((s) => s.id != id).toList();
      notifyListeners();
      return;
    }
    final s = byId(id);
    if (s == null) {
      // A session created elsewhere: pick it up on the next (debounced) list.
      _refreshDebounce?.cancel();
      _refreshDebounce = Timer(const Duration(seconds: 1), () => unawaited(refresh()));
      return;
    }
    s.state = a['state'] as String? ?? s.state;
    s.pending = (a['pending'] as num?)?.toInt() ?? s.pending;
    s.queued = (a['queued'] as num?)?.toInt() ?? s.queued;
    if (a['title'] is String) s.title = a['title'] as String;
    final updated = DateTime.tryParse(a['updatedAt'] as String? ?? '');
    if (updated != null) s.updatedAt = updated;
    s.known = true;
    sessions.sort((x, y) => (y.updatedAt ?? DateTime(0)).compareTo(x.updatedAt ?? DateTime(0)));
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _activitySub?.cancel();
    _connSub?.cancel();
    _refreshDebounce?.cancel();
    super.dispose();
  }
}
