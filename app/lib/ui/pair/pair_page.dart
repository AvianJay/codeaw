import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app_state.dart';
import '../../data/host.dart';

class PairPage extends StatefulWidget {
  const PairPage({super.key});

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final _url = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController(text: 'Android 手機');
  bool _busy = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.read(context);
    final link = state.pendingPairing;
    if (link != null) {
      state.pendingPairing = null;
      _fill(link);
    }
  }

  void _fill(PairingLink link) {
    _url.text = link.urls.first;
    _code.text = link.code;
    _pending = link;
  }

  PairingLink? _pending;

  Future<void> _scan() async {
    final raw = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _ScanPage()));
    if (raw == null || !mounted) return;
    final link = PairingLink.parse(raw);
    if (link == null) {
      setState(() => _error = '這不是 codeaw 的配對 QR code');
      return;
    }
    setState(() => _fill(link));
    await _pair();
  }

  Future<void> _pair() async {
    final url = _url.text.trim();
    final code = _code.text.trim();
    if (url.isEmpty || code.isEmpty) {
      setState(() => _error = '請填入 bridge 網址與配對碼');
      return;
    }
    final normalized = url.contains('://') ? url : 'ws://$url';
    final withPath = Uri.parse(normalized).path.isEmpty || Uri.parse(normalized).path == '/' ? '${normalized.replaceAll(RegExp(r'/+$'), '')}/acp' : normalized;
    final pending = _pending;
    final link = PairingLink(
      [withPath, if (pending != null) ...pending.urls.where((u) => u != withPath)],
      code,
      pending?.hostName,
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = AppScope.read(context);
    final router = GoRouter.of(context);
    try {
      final host = await pairWithBridge(link, _name.text.trim().isEmpty ? 'Android' : _name.text.trim());
      await state.setHost(host);
      await state.notifier.requestPermission();
      router.go('/');
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final paired = AppScope.of(context).paired;
    return Scaffold(
      appBar: AppBar(title: const Text('配對電腦'), automaticallyImplyLeading: paired),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('在電腦上執行', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
            child: const SelectableText('codeaw-bridge pair', style: TextStyle(fontFamily: 'monospace')),
          ),
          const SizedBox(height: 8),
          Text('手機需先開啟 Tailscale，再掃描終端機上的 QR code。', style: TextStyle(color: scheme.outline)),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _scan,
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('掃描 QR code'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
          const SizedBox(height: 28),
          Row(children: [
            const Expanded(child: Divider()),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text('或手動輸入', style: TextStyle(color: scheme.outline))),
            const Expanded(child: Divider()),
          ]),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Bridge 網址', hintText: 'ws://100.x.y.z:7860/acp', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '配對碼', hintText: 'XXXX-XXXX', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: '這台裝置的名稱', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          OutlinedButton(
            onPressed: _busy ? null : _pair,
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('配對'),
          ),
        ],
      ),
    );
  }
}

class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool _done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('掃描配對 QR code')),
      body: MobileScanner(
        onDetect: (capture) {
          if (_done) return;
          for (final b in capture.barcodes) {
            final v = b.rawValue;
            if (v != null && v.startsWith('codeaw://')) {
              _done = true;
              Navigator.of(context).pop(v);
              return;
            }
          }
        },
      ),
    );
  }
}
