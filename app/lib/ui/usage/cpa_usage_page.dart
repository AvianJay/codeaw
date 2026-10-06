import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../data/cpa_usage.dart';
import '../common/adaptive.dart';
import '../common/widgets.dart';
import 'quota_color.dart';

class CpaUsagePage extends StatefulWidget {
  const CpaUsagePage({super.key, this.controller});
  final CpaController? controller;
  @override
  State<CpaUsagePage> createState() => _CpaUsagePageState();
}

class _CpaUsagePageState extends State<CpaUsagePage> {
  CpaController? _boundController;
  CpaController get _controller => _boundController!;
  final _search = TextEditingController();
  String? _provider;
  @override
  void initState() {
    super.initState();
    _bind(widget.controller);
  }

  void _bind(CpaController? controller) {
    if (identical(controller, _boundController)) return;
    _boundController = controller;
    if (controller == null) return;
    if (!controller.initialized) unawaited(controller.initialize());
    controller.startAutoRefresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.controller == null) _bind(AppScope.of(context).cpa);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _configure() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final value = await showModalBottomSheet<CpaSettings>(
      context: context,
      isScrollControlled: true,
      requestFocus: false,
      builder: (_) => _ConnectionSheet(settings: _controller.settings),
    );
    if (value == null || !mounted) return;
    if (value.endpoint.isEmpty) {
      await _controller.forget();
      return;
    }
    try {
      await _controller.configure(value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('無法儲存 CPA 連線設定，請重試')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_boundController == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('CPA 用量')),
        body: const Center(child: Text('請先連上電腦 bridge')),
      );
    }
    return _buildUsage(context);
  }

  Widget _buildUsage(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final c = _controller, scheme = Theme.of(context).colorScheme;
      final query = _search.text.trim().toLowerCase();
      final accounts = c.accounts
          .where(
            (a) =>
                (_provider == null || _provider == a.provider) &&
                '${a.label} ${a.providerLabel} ${c.quotas[a.id]?.plan ?? a.plan ?? ''}'
                    .toLowerCase()
                    .contains(query),
          )
          .toList();
      final providers = c.accounts.map((a) => a.provider).toSet().toList()
        ..sort();
      final endpoint = Uri.tryParse(c.settings?.endpoint ?? '');
      final averages = cpaProviderAverages(c.accounts, c.quotas);
      return Scaffold(
        appBar: AppBar(
          title: const Text('用量與額度'),
          actions: [
            IconButton(
              tooltip: 'CPA 連線設定',
              onPressed: _configure,
              icon: const Icon(Icons.tune_rounded),
            ),
            IconButton(
              tooltip: '重新整理額度',
              onPressed:
                  c.settings != null &&
                      !c.loading &&
                      c.loadingQuotas.isEmpty
                  ? c.refresh
                  : null,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: ContentScrollFrame(
          maxWidth: 1040,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          builder: (context, padding) {
            if (!c.initialized) {
              return const Center(child: CircularProgressIndicator());
            }
            if (c.settings == null) {
              return ListView(
                padding: padding,
                children: [
                  const SizedBox(height: 52),
                  Icon(
                    Icons.donut_large_rounded,
                    size: 44,
                    color: scheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '你的帳號額度，一眼看清',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '連接 CLI Proxy API，查看 Codex、Claude、Grok 等帳號的用量、重置時間與可用重置次數。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: FilledButton.icon(
                      onPressed: _configure,
                      icon: const Icon(Icons.add_link_rounded),
                      label: const Text('連接 CPA'),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    '使用 CPA 的 Management Key。設定儲存在此裝置；由已配對的電腦代為查詢。',
                    textAlign: TextAlign.center,
                  ),
                  if (c.error != null)
                    Text(c.error!, textAlign: TextAlign.center),
                ],
              );
            }
            return RefreshIndicator(
              onRefresh: c.refresh,
              child: ListView(
                padding: padding,
                physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  if (averages.isNotEmpty) ...[
                    for (final average in averages)
                      _ProviderAverageRow(average: average),
                    const SizedBox(height: 12),
                    const Divider(),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      Icon(
                        Icons.hub_outlined,
                        size: 17,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${endpoint?.host ?? 'CPA'}${endpoint?.hasPort == true ? ':${endpoint!.port}' : ''}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Text(
                        '${c.accounts.length} 個帳號',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    c.loading
                        ? '正在讀取帳號…'
                        : c.loadingQuotas.isNotEmpty
                        ? '更新額度中 · 剩 ${c.loadingQuotas.length} 個'
                        : c.updatedAt != null
                        ? '更新於 ${cpaResetDate(c.updatedAt)} · 額度不會自動兌換或重置'
                        : '尚未更新',
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    onTapOutside: (_) =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                    decoration: InputDecoration(
                      hintText: '搜尋帳號、類型或方案',
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        size: 20,
                      ),
                      isDense: true,
                      suffixIcon: query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清除搜尋',
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () {
                                _search.clear();
                                setState(() {});
                              },
                            ),
                    ),
                  ),
                  if (providers.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _Filter(
                              label: '全部',
                              selected: _provider == null,
                              onTap: () =>
                                  setState(() => _provider = null),
                            ),
                            for (final provider in providers)
                              _Filter(
                                label: c.accounts
                                    .firstWhere(
                                      (a) => a.provider == provider,
                                    )
                                    .providerLabel,
                                selected: _provider == provider,
                                onTap: () =>
                                    setState(() => _provider = provider),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (c.error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            color: scheme.error,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              c.error!,
                              style: TextStyle(color: scheme.error),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (c.loading)
                    const LinearProgressIndicator(minHeight: 2),
                  if (!c.loading && accounts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 48),
                      child: Text(
                        query.isNotEmpty || _provider != null
                            ? '沒有符合的帳號'
                            : c.error != null
                            ? '檢查連線設定後重新整理'
                            : 'CPA 尚未加入帳號',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  for (final account in accounts) ...[
                    _AccountRow(
                      account: account,
                      quota: c.quotas[account.id],
                      loading: c.loadingQuotas.contains(account.id),
                      onRefresh: () => c.refreshAccount(account.id),
                    ),
                    const Divider(),
                  ],
                  if (accounts.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        '百分比代表剩餘額度。重置時間依裝置時區顯示；服務商未提供的值會標示未知。',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.outline,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
}

class _ProviderAverageRow extends StatelessWidget {
  const _ProviderAverageRow({required this.average});
  final CpaProviderAverage average;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: ValueKey('cpa-average-${average.provider}'),
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Row(
              children: [
                AgentAvatar(
                  agentId: average.provider,
                  label: average.label,
                  size: 22,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        average.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${average.totalAccounts} 個帳號',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final weekly = _AverageBar(
                  provider: average,
                  label: '週',
                  average: average.weekly,
                );
                final fiveHour = _AverageBar(
                  provider: average,
                  label: '5hr',
                  average: average.fiveHour,
                );
                if (constraints.maxWidth <
                    MediaQuery.textScalerOf(context).scale(160)) {
                  return Column(
                    children: [weekly, const SizedBox(height: 9), fiveHour],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: weekly),
                    const SizedBox(width: 14),
                    Expanded(child: fiveHour),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _AverageBar extends StatelessWidget {
  const _AverageBar({
    required this.provider,
    required this.label,
    required this.average,
  });
  final CpaProviderAverage provider;
  final String label;
  final CpaUsageAverage average;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = average.remainingPercent;
    final color = cpaQuotaColor(context, value);
    final formatted = value == null ? '—' : '${value.toStringAsFixed(1)}%';
    final coverage = average.accountCount < provider.totalAccounts
        ? ' (${average.accountCount}/${provider.totalAccounts})'
        : '';
    final explanation =
        '${provider.label} $label 平均剩餘額度：$formatted。'
        '有效帳號 ${average.accountCount}/${provider.totalAccounts}；'
        '未知、失敗、停用或不可用帳號不納入，搜尋與篩選不影響平均。'
        '${provider.provider == 'antigravity' ? 'AGY 先平均各帳號的模型群組，再平均帳號。' : ''}';
    return Tooltip(
      message: explanation,
      child: Semantics(
        label: explanation,
        excludeSemantics: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$label: $formatted$coverage',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 5),
            LinearProgressIndicator(
              value: value == null ? 0 : value / 100,
              minHeight: 3,
              color: color,
              backgroundColor: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(3),
            ),
          ],
        ),
      ),
    );
  }
}

class _Filter extends StatelessWidget {
  const _Filter({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
    ),
  );
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    required this.quota,
    required this.loading,
    required this.onRefresh,
  });
  final CpaAccount account;
  final CpaQuota? quota;
  final bool loading;
  final VoidCallback onRefresh;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plan = quota?.plan ?? account.plan;
    final status = account.disabled
        ? '停用'
        : account.unavailable
        ? '不可用'
        : account.status == 'active'
        ? '可用'
        : account.status == 'error'
        ? '錯誤'
        : '未確認';
    return Padding(
      key: ValueKey('cpa-account-${account.id}'),
      padding: const EdgeInsets.symmetric(vertical: 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AgentAvatar(
                agentId: account.provider,
                label: account.providerLabel,
                size: 34,
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${account.providerLabel}${plan != null ? ' · $plan' : ''}${account.requests != null ? ' · ${account.requests} 次請求' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                status,
                style: TextStyle(
                  fontSize: 11,
                  color: account.disabled
                      ? scheme.outline
                      : account.unavailable
                      ? scheme.error
                      : scheme.primary,
                ),
              ),
              SizedBox(
                width: 36,
                height: 36,
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : IconButton(
                        tooltip: '更新 ${account.label} 額度',
                        onPressed: account.disabled ? null : onRefresh,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (quota?.windows.isNotEmpty == true)
            LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 640;
                return Wrap(
                  spacing: 24,
                  runSpacing: 10,
                  children: [
                    for (final window in quota!.windows)
                      SizedBox(
                        width: wide
                            ? (constraints.maxWidth - 24) / 2
                            : constraints.maxWidth,
                        child: _QuotaLine(window: window),
                      ),
                  ],
                );
              },
            )
          else
            Text(
              account.disabled
                  ? '帳號已停用'
                  : loading
                  ? '正在查詢服務商額度…'
                  : quota?.message ?? '額度尚未更新',
              style: TextStyle(
                fontSize: 12,
                color: quota?.status == 'error' ? scheme.error : scheme.outline,
              ),
            ),
          if (account.provider == 'codex' || quota?.subscriptionUntil != null)
            Padding(
              padding: const EdgeInsets.only(top: 9),
              child: Wrap(
                spacing: 16,
                runSpacing: 5,
                children: [
                  if (account.provider == 'codex')
                    Text(
                      '↻ 可用重置 ${quota?.resetsRemaining == null ? '未知' : '${quota!.resetsRemaining} 次'}',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  if (quota?.subscriptionUntil != null)
                    Text(
                      '方案到期 ${cpaResetDate(quota!.subscriptionUntil)}',
                      style: TextStyle(fontSize: 11, color: scheme.outline),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _QuotaLine extends StatelessWidget {
  const _QuotaLine({required this.window});
  final CpaWindow window;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme,
        left = window.remainingPercent;
    final color = cpaQuotaColor(context, left);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                window.label,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            Text(
              left == null
                  ? '未知'
                  : '剩餘 ${left.toStringAsFixed(left == left.roundToDouble() ? 0 : 1)}%',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: left == null ? 0 : left.clamp(0, 100) / 100,
            color: color,
            minHeight: 3,
            backgroundColor: scheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          '${cpaResetCountdown(window.resetAt, DateTime.now())}${window.resetAt != null ? ' · ${cpaResetDate(window.resetAt)}' : ''}',
          style: TextStyle(fontSize: 10.5, color: scheme.outline),
        ),
      ],
    );
  }
}

class _ConnectionSheet extends StatefulWidget {
  const _ConnectionSheet({this.settings});
  final CpaSettings? settings;
  @override
  State<_ConnectionSheet> createState() => _ConnectionSheetState();
}

class _ConnectionSheetState extends State<_ConnectionSheet> {
  final _form = GlobalKey<FormState>();
  late final _endpoint = TextEditingController(
    text: widget.settings?.endpoint ?? '',
  );
  late final _key = TextEditingController(
    text: widget.settings?.managementKey ?? '',
  );
  bool _showKey = false;
  @override
  void dispose() {
    _endpoint.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        22,
        22,
        22,
        MediaQuery.viewInsetsOf(context).bottom + 22,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '連接 CLI Proxy API',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _endpoint,
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'CPA 端點',
                  hintText: 'https://cpa.example.com',
                  helperText: '支援根網址或 /v0/management、/v8/management',
                ),
                validator: (v) {
                  final uri = Uri.tryParse(v?.trim() ?? '');
                  return uri != null &&
                          ['http', 'https'].contains(uri.scheme) &&
                          uri.host.isNotEmpty &&
                          uri.userInfo.isEmpty &&
                          !uri.hasQuery &&
                          !uri.hasFragment
                      ? null
                      : '請輸入有效的 HTTP(S) 網址';
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _key,
                obscureText: !_showKey,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Management Key',
                  helperText: '管理密鑰，不是給模型使用的 API key',
                  suffixIcon: IconButton(
                    tooltip: _showKey ? '隱藏密鑰' : '顯示密鑰',
                    onPressed: () => setState(() => _showKey = !_showKey),
                    icon: Icon(
                      _showKey
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
                validator: (v) =>
                    v?.trim().isNotEmpty == true ? null : '請輸入 Management Key',
              ),
              const SizedBox(height: 18),
              Text(
                '密鑰儲存在此裝置，查詢時傳給已配對的 bridge，再由電腦連線 CPA。只讀取帳號與額度，不兌換重置次數。Web 版請只在可信任的瀏覽器使用。',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    if (_form.currentState!.validate()) {
                      FocusManager.instance.primaryFocus?.unfocus();
                      Navigator.pop(
                        context,
                        CpaSettings(
                          endpoint: _endpoint.text.trim(),
                          managementKey: _key.text.trim(),
                        ),
                      );
                    }
                  },
                  child: const Text('儲存並連線'),
                ),
              ),
              if (widget.settings != null)
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(
                      context,
                      const CpaSettings(endpoint: '', managementKey: ''),
                    ),
                    child: const Text('移除 CPA 連線'),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
