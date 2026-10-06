/// Durable app-private storage, injected in tests without platform plugins.
abstract interface class HistoryStorage {
  Future<Map<String, dynamic>?> read(String host, String session);
  Future<void> write(String host, String session, Map<String, dynamic> value);
  Future<void> remove(String host, String session);
  Future<void> clear(String host);
}
