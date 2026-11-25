import 'package:flutter/material.dart';

import '../../data/live_activity.dart';

class LiveActivitySettings extends StatelessWidget {
  const LiveActivitySettings({super.key, required this.controller});
  final LiveActivityController controller;

  /// What stops the location session from starting, if anything.
  String? get _locationProblem {
    if (!controller.locationEnabled) return null;
    if (controller.locationError != null) return controller.locationError;
    if (!controller.locationServicesEnabled) {
      return '請開啟 iPhone 的定位服務，再回到 Codeaw。';
    }
    return switch (controller.locationAuthorization) {
      'denied' ||
      'restricted' => '定位權限未允許，請到 iPhone「設定 → Codeaw → 位置」開啟，再回到 App。',
      'notDetermined' => '尚未取得定位權限。請關閉再開啟此選項，並允許「使用 App 期間」。',
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final locationProblem = _locationProblem;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.motion_photos_on_rounded),
            title: const Text('Dynamic Island 與鎖定畫面'),
            subtitle: Text(
              controller.authorized
                  ? '顯示執行中聊天的進度'
                  : '請在 iPhone「設定 → Codeaw」允許即時動態',
            ),
            value: controller.enabled,
            onChanged: (value) => controller.configure(enabled: value),
          ),
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.visibility_outlined),
            title: const Text('顯示聊天標題、專案與工作摘要'),
            subtitle: const Text('關閉後只顯示工作狀態'),
            value: controller.showDetails,
            onChanged: controller.enabled
                ? (value) => controller.configure(showDetails: value)
                : null,
          ),
          if (controller.keepAliveSupported)
            SwitchListTile.adaptive(
              secondary: const Icon(Icons.sync_rounded),
              title: const Text('背景持續更新'),
              subtitle: const Text('AI 工作時讓 App 留在背景保持連線，結束後自動停止'),
              value: controller.keepAliveEnabled,
              onChanged: controller.enabled
                  ? (value) => controller.configure(keepAliveEnabled: value)
                  : null,
            ),
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.location_on_outlined),
            title: const Text('用定位服務保持連線'),
            subtitle: const Text('上一項維持不住更新時再開。座標不儲存、不傳到電腦，會顯示定位指示'),
            value: controller.locationEnabled,
            onChanged: controller.enabled && controller.locationSupported
                ? (value) => controller.configure(locationEnabled: value)
                : null,
          ),
          if (locationProblem != null)
            ListTile(
              leading: Icon(
                Icons.location_off_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(locationProblem),
            ),
          // Only a bridge with an Apple push key has anything to report here.
          if (controller.remoteReady)
            ListTile(
              leading: Icon(
                controller.pushRegistered
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined,
              ),
              title: Text(
                controller.pushRegistered
                    ? '鎖定後由電腦經 Apple 推播更新'
                    : '尚未註冊 Apple 推播',
              ),
              subtitle: Text(
                controller.pushRegistered
                    ? (controller.remoteDetails ? '推播包含工作摘要' : '推播只含工作狀態')
                    : '開始工作後會再試一次；安裝簽名需要有推播權限',
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
      );
    },
  );
}
