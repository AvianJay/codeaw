import 'package:flutter/material.dart';

import '../../data/live_activity.dart';

class LiveActivitySettings extends StatelessWidget {
  const LiveActivitySettings({super.key, required this.controller});
  final LiveActivityController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.motion_photos_on_rounded),
          title: const Text('Dynamic Island 與鎖定畫面'),
          subtitle: Text(
            controller.authorized
                ? '開過的聊天開始工作時，顯示專案、計時與 AI 狀態'
                : '請在 iPhone「設定 → Codeaw」允許即時動態',
          ),
          value: controller.enabled,
          onChanged: (value) => controller.configure(enabled: value),
        ),
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.visibility_outlined),
          title: const Text('顯示專案與工作摘要'),
          subtitle: const Text('鎖定畫面可看見專案名稱、指令及 agent 已提供的思考摘要；關閉後只顯示工作狀態'),
          value: controller.showDetails,
          onChanged: controller.enabled
              ? (value) => controller.configure(showDetails: value)
              : null,
        ),
        ListTile(
          leading: Icon(
            controller.remoteReady
                ? Icons.cloud_done_outlined
                : Icons.cloud_off_outlined,
          ),
          title: Text(
            controller.remoteReady ? 'APNs 背景更新已設定' : '目前使用 App 連線更新',
          ),
          subtitle: Text(
            controller.remoteReady
                ? '${controller.pushRegistered ? '已取得即時動態推播權杖，鎖定後由 bridge 經 Apple APNs 更新。' : '尚未註冊推播權杖，開始工作後會再嘗試；請確認安裝簽名具備推播權限。'}${controller.remoteDetails ? '推送可包含工作摘要。' : 'Bridge 目前只推送一般狀態。'}'
                : '計時會繼續；iOS 暫停 App 後，指令與摘要可能停止更新，2 分鐘後標示「狀態待同步」。持續背景更新需要 Apple APNs 金鑰及相符的推播簽名。',
          ),
        ),
        if (controller.error != null)
          ListTile(
            leading: Icon(
              Icons.info_outline_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(controller.error!),
          ),
      ],
    ),
  );
}
