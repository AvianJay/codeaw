import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../data/host.dart';

Future<void> showHostSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (_) => const _HostSheet(),
);

class _HostSheet extends StatefulWidget {
  const _HostSheet();

  @override
  State<_HostSheet> createState() => _HostSheetState();
}

class _HostSheetState extends State<_HostSheet> {
  HostConfig? _switching;
  String? _error;

  Future<void> _select(HostConfig host) async {
    final state = AppScope.read(context);
    if (identical(state.host, host)) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _switching = host;
      _error = null;
    });
    try {
      await state.setHost(host);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _switching = null;
          _error = '無法切換電腦，請再試一次';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text('切換電腦', style: Theme.of(context).textTheme.titleLarge),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final host in state.hosts)
                  ListTile(
                    leading: const Icon(Icons.computer_rounded),
                    title: Text(
                      host.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${identical(state.host, host) ? '目前電腦 · ' : ''}${HostConfig.httpBase(host.urls.first).authority}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: identical(state.host, host),
                    trailing: identical(_switching, host)
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : identical(state.host, host)
                        ? Icon(Icons.check_rounded, color: scheme.primary)
                        : null,
                    onTap: _switching == null ? () => _select(host) : null,
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.add_rounded),
            title: const Text('新增電腦'),
            subtitle: const Text('掃描 QR code 或輸入配對碼'),
            onTap: _switching == null
                ? () {
                    final router = GoRouter.of(context);
                    Navigator.pop(context);
                    router.push('/pair');
                  }
                : null,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
