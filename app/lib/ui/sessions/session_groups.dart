import '../../data/models.dart';

/// One dated section of the session list.
class SessionDateGroup {
  SessionDateGroup(this.label);
  final String label;
  final sessions = <SessionSummary>[];
}

/// The heading a conversation last used at [time] belongs under, by local calendar day.
String sessionDateLabel(DateTime? time, DateTime now) {
  if (time == null) return '更早';
  final local = time.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final days = today.difference(DateTime(local.year, local.month, local.day)).inHours / 24;
  // A clock a little ahead of this device still means "today".
  if (days < 1) return '今天';
  if (days < 2) return '昨天';
  if (days < 7) return '過去 7 天';
  if (days < 30) return '過去 30 天';
  return local.year == now.year ? '${local.month} 月' : '${local.year} 年 ${local.month} 月';
}

/// Splits [sessions] into newest-first dated sections.
List<SessionDateGroup> groupSessionsByDate(Iterable<SessionSummary> sessions, DateTime now) {
  final sorted = sessions.toList()
    ..sort((a, b) => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));
  final groups = <SessionDateGroup>[];
  for (final s in sorted) {
    final label = sessionDateLabel(s.updatedAt, now);
    if (groups.isEmpty || groups.last.label != label) groups.add(SessionDateGroup(label));
    groups.last.sessions.add(s);
  }
  return groups;
}
