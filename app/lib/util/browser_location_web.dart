import 'package:web/web.dart' as web;

/// Read the one-time launch code in memory, then remove it before routing/reload.
void clearBrowserPairing() {
  final uri = Uri.base;
  final params = Map<String, String>.from(uri.queryParameters)
    ..remove('pair')
    ..remove('c')
    ..remove('n');
  final clean = uri.replace(
    query: params.isEmpty ? '' : Uri(queryParameters: params).query,
    fragment: '/',
  );
  web.window.history.replaceState(null, '', clean.toString());
}
