import '../data/app_updater.dart';

Future<void> downloadAndInstallApk(
  UpdateAsset asset,
  void Function(double progress) onProgress,
) async {
  throw const UpdateException('此平台不支援 APK 安裝');
}
