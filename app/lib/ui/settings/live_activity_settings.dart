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
                ? '各個執行中的聊天會顯示標題、專案、計時與 AI 狀態'
                : '請在 iPhone「設定 → Codeaw」允許即時動態',
          ),
          value: controller.enabled,
          onChanged: (value) => controller.configure(enabled: value),
        ),
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.visibility_outlined),
          title: const Text('顯示聊天標題、專案與工作摘要'),
          subtitle: const Text(
            '鎖定畫面可看見聊天標題、專案名稱、指令及 agent 已提供的思考摘要；關閉後只顯示工作狀態',
          ),
          value: controller.showDetails,
          onChanged: controller.enabled
              ? (value) => controller.configure(showDetails: value)
              : null,
        ),
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.location_on_outlined),
          title: const Text('背景定位維持同步'),
          subtitle: const Text(
            '預設關閉。AI 工作時使用 iOS 定位服務，嘗試讓鎖屏後的指令與完成狀態持續更新。'
            '座標不儲存、不傳到電腦；會顯示定位指示並增加耗電。強制關閉 App 後無法更新。',
          ),
          value: controller.locationEnabled,
          onChanged: controller.enabled && controller.locationSupported
              ? (value) => controller.configure(locationEnabled: value)
              : null,
        ),
        if (controller.locationEnabled)
          ListTile(
            leading: Icon(
              controller.locationActive
                  ? Icons.location_on_rounded
                  : Icons.location_off_outlined,
            ),
            title: Text(controller.locationActive ? '背景定位同步已啟動' : '背景定位同步未啟動'),
            subtitle: Text(
              controller.locationError ??
                  (!controller.locationServicesEnabled
                      ? '請開啟 iPhone 的定位服務，再回到 Codeaw。'
                      : {
                          'denied',
                          'restricted',
                        }.contains(controller.locationAuthorization)
                      ? '定位權限未允許，請到 iPhone「設定 → Codeaw → 位置」開啟，再回到 App。'
                      : controller.locationAuthorization == 'notDetermined'
                      ? '尚未取得定位權限。請在 App 前景關閉並重新開啟此選項，允許「使用 App 期間」。'
                      : controller.locationActive
                      ? '工作全部結束、關閉即時動態或切換電腦時停止。iOS 仍可能限制背景執行；請在實機鎖屏後確認。'
                      : '下一次在 App 前景開始 AI 工作時啟動；沒有工作時不使用定位服務。'),
            ),
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
                : '計時會繼續並顯示上次同步時間；兩分鐘未同步會標示「更新已暫停」。可選擇上方的背景定位模式嘗試維持連線，或設定 Apple APNs 金鑰及相符的推播簽名。',
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
