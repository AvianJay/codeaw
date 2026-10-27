import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../util/apk_installer.dart';

enum UpdateChannel {
  release,
  nightly;

  static UpdateChannel get forBuild => parse(
    const String.fromEnvironment(
      'CODEAW_UPDATE_CHANNEL',
      defaultValue: 'release',
    ),
  );

  static UpdateChannel parse(String value) => switch (value) {
    'release' => release,
    'nightly' => nightly,
    _ => throw const FormatException('Unknown update channel'),
  };
}

enum IosInstaller {
  altStore('AltStore'),
  sideStore('SideStore'),
  liveContainer('LiveContainer'),
  lcSign('LCSign'),
  custom('自訂安裝工具'),
  browser('瀏覽器下載');

  const IosInstaller(this.label);
  final String label;

  Uri installUri(Uri download, {String? customTemplate}) => switch (this) {
    altStore || sideStore || liveContainer => Uri(
      scheme: switch (this) {
        altStore => 'altstore',
        sideStore => 'sidestore',
        _ => 'livecontainer',
      },
      host: 'install',
      queryParameters: {'url': download.toString()},
    ),
    lcSign => Uri(
      scheme: 'loadcontroller',
      host: 'import',
      queryParameters: {'url': download.toString()},
    ),
    custom => customInstallUri(download, customTemplate ?? ''),
    browser => download,
  };
}

Uri customInstallUri(Uri download, String template) {
  final value = template.trim();
  if (!value.contains('{url}')) {
    throw const UpdateException('安裝連結需要包含 {url}，用來代入 IPA 下載連結');
  }
  final uri = Uri.tryParse(
    value.replaceAll('{url}', Uri.encodeComponent(download.toString())),
  );
  if (uri == null ||
      !uri.hasScheme ||
      ['file', 'data', 'javascript'].contains(uri.scheme.toLowerCase())) {
    throw const UpdateException('請輸入安裝工具提供的完整 URL Scheme 或 HTTPS 連結');
  }
  return uri;
}

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

class UpdateAsset {
  const UpdateAsset({
    required this.url,
    required this.sha256,
    required this.size,
  });
  final Uri url;
  final String sha256;
  final int size;

  factory UpdateAsset.fromJson(Map<String, dynamic> json) {
    final url = Uri.parse(json['url'] as String);
    final digest = json['sha256'] as String;
    final size = json['size'] as int;
    if (url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(digest) ||
        size <= 0) {
      throw const FormatException('Invalid update asset');
    }
    return UpdateAsset(url: url, sha256: digest.toLowerCase(), size: size);
  }
}

class AppRelease {
  const AppRelease({
    required this.channel,
    required this.version,
    required this.buildNumber,
    required this.pageUrl,
    required this.assets,
  });

  final UpdateChannel channel;
  final Version version;
  final int buildNumber;
  final Uri pageUrl;
  final Map<String, UpdateAsset> assets;
  String get displayVersion => '$version+$buildNumber';

  factory AppRelease.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported update manifest');
    }
    final page = Uri.parse(json['releaseUrl'] as String);
    final build = json['buildNumber'] as int;
    if (build <= 0 || page.scheme != 'https' || page.host != 'github.com') {
      throw const FormatException('Invalid release');
    }
    return AppRelease(
      channel: UpdateChannel.parse(json['channel'] as String),
      version: Version.parse(json['version'] as String),
      buildNumber: build,
      pageUrl: page,
      assets: {
        for (final entry in (json['assets'] as Map<String, dynamic>).entries)
          entry.key: UpdateAsset.fromJson(entry.value as Map<String, dynamic>),
      },
    );
  }

  bool isNewerThan(String installedVersion, String installedBuild) {
    final compared = version.compareTo(Version.parse(installedVersion));
    return compared > 0 ||
        (compared == 0 && buildNumber > (int.tryParse(installedBuild) ?? 0));
  }
}

typedef UpdateUrlLauncher = Future<bool> Function(Uri url);
typedef ApkInstall =
    Future<void> Function(
      UpdateAsset asset,
      void Function(double progress) onProgress,
    );

/// Independent of bridge connectivity; never installs without a user action.
class AppUpdater extends ChangeNotifier {
  AppUpdater({
    http.Client? client,
    UpdateChannel? buildChannel,
    this.repository = const String.fromEnvironment(
      'CODEAW_UPDATE_REPOSITORY',
      defaultValue: 'AvianJay/codeaw',
    ),
    Future<PackageInfo> Function()? loadPackage,
    ApkInstall? installApk,
    UpdateUrlLauncher? openUrl,
    TargetPlatform? platform,
    bool? isWeb,
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       buildChannel = buildChannel ?? UpdateChannel.forBuild,
       _loadPackage = loadPackage ?? PackageInfo.fromPlatform,
       _installApk = installApk ?? downloadAndInstallApk,
       _openUrl = openUrl ?? _launchExternal,
       platform = platform ?? defaultTargetPlatform,
       isWeb = isWeb ?? kIsWeb,
       _now = now ?? DateTime.now {
    channel = this.buildChannel;
  }

  final http.Client _client;
  final UpdateChannel buildChannel;
  final String repository;
  final Future<PackageInfo> Function() _loadPackage;
  final ApkInstall _installApk;
  final UpdateUrlLauncher _openUrl;
  final TargetPlatform platform;
  final bool isWeb;
  final DateTime Function() _now;
  late UpdateChannel channel;
  IosInstaller iosInstaller = IosInstaller.browser;
  String customIosInstaller = '';
  PackageInfo? installed;
  AppRelease? release;
  DateTime? checkedAt;
  bool checking = false;
  bool installing = false;
  double? progress;
  String? error;
  String? message;
  SharedPreferences? _preferences;
  Future<void>? _initializing;
  DateTime? _lastCheckAttempt;
  bool _disposed = false;

  bool get supported =>
      !isWeb &&
      (platform == TargetPlatform.android || platform == TargetPlatform.iOS);
  bool get busy => checking || installing || installed == null;
  String get installedVersion => installed == null
      ? '讀取中…'
      : '${installed!.version}+${installed!.buildNumber}';
  bool get switchingChannel => channel != buildChannel;
  bool get updateAvailable =>
      release != null &&
      installed != null &&
      (switchingChannel ||
          release!.isNewerThan(installed!.version, installed!.buildNumber));
  UpdateAsset? get asset =>
      release?.assets[switch (platform) {
        TargetPlatform.android => 'android',
        TargetPlatform.iOS => 'ios',
        _ => '',
      }];
  String get _channelKey => 'codeaw.updater.channel.${buildChannel.name}';
  String get _promptKey =>
      'codeaw.updater.prompted.${buildChannel.name}.${channel.name}';
  String? get availableUpdateId =>
      supported && updateAvailable && asset != null && !checking && !installing
      ? '${channel.name}:${release!.displayVersion}'
      : null;
  bool get shouldPromptUpdate =>
      availableUpdateId != null &&
      _preferences?.getString(_promptKey) != availableUpdateId;
  String? get customIosInstallerError {
    try {
      customInstallUri(asset?.url ?? releasePage, customIosInstaller);
      return null;
    } on UpdateException catch (e) {
      return e.message;
    }
  }

  Uri get releasePage => Uri.https(
    'github.com',
    '/$repository/releases/${channel == UpdateChannel.nightly ? 'tag/nightly' : 'latest'}',
  );
  Uri get manifestUrl => Uri.https(
    'github.com',
    '/$repository/releases/${channel == UpdateChannel.nightly ? 'download/nightly' : 'latest/download'}/app-update.json',
    // Nightly assets are replaced in place. Avoid a cached manifest.
    {'t': _now().millisecondsSinceEpoch.toString()},
  );

  static Future<bool> _launchExternal(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    try {
      if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repository)) {
        throw const UpdateException('更新來源設定錯誤');
      }
      final package = await _loadPackage();
      Version.parse(package.version);
      final prefs = await SharedPreferences.getInstance();
      if (_disposed) return;
      installed = package;
      _preferences = prefs;
      final savedChannel = prefs.getString(_channelKey);
      channel = UpdateChannel.values.firstWhere(
        (value) => value.name == savedChannel,
        orElse: () => buildChannel,
      );
      iosInstaller = IosInstaller.values.firstWhere(
        (value) => value.name == prefs.getString('codeaw.updater.iosInstaller'),
        orElse: () => IosInstaller.browser,
      );
      customIosInstaller =
          prefs.getString('codeaw.updater.customIosInstaller') ?? '';
      _emit();
      if (supported) await check();
    } catch (_) {
      if (_disposed) return;
      error = '無法讀取 App 版本，請重試';
      _initializing = null;
      _emit();
    }
  }

  Future<void> setChannel(UpdateChannel value) async {
    if (busy || value == channel || _disposed) return;
    if (!await _preferences!.setString(_channelKey, value.name)) {
      error = '無法儲存更新頻道，請重試';
      _emit();
      return;
    }
    if (_disposed) return;
    channel = value;
    release = null;
    checkedAt = null;
    message = null;
    error = null;
    _emit();
    if (supported) await check();
  }

  Future<void> setIosInstaller(IosInstaller value) async {
    if (busy || _disposed) return;
    if (!await _preferences!.setString(
      'codeaw.updater.iosInstaller',
      value.name,
    )) {
      error = '無法儲存安裝方式，請重試';
      _emit();
      return;
    }
    if (_disposed) return;
    iosInstaller = value;
    _emit();
  }

  Future<void> setCustomIosInstaller(String value) async {
    if (busy || _disposed) return;
    customIosInstaller = value.trim();
    _emit();
    if (!await _preferences!.setString(
          'codeaw.updater.customIosInstaller',
          customIosInstaller,
        ) &&
        !_disposed) {
      error = '無法儲存自訂安裝方式，請重試';
      _emit();
    }
  }

  Future<void> markUpdatePromptShown() async {
    final id = availableUpdateId;
    if (id != null) await _preferences?.setString(_promptKey, id);
  }

  Future<void> checkIfStale({
    Duration minAge = const Duration(minutes: 15),
  }) async {
    if (_lastCheckAttempt != null &&
        _now().difference(_lastCheckAttempt!) < minAge) {
      return;
    }
    await check();
  }

  Future<void> check() async {
    if (_disposed || checking || installing || !supported) return;
    if (installed == null) {
      await initialize();
      return;
    }
    checking = true;
    _lastCheckAttempt = _now();
    release = null;
    error = null;
    message = null;
    _emit();
    try {
      final response = await _client
          .get(manifestUrl, headers: {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 20));
      if (_disposed) return;
      if (response.statusCode == 404) {
        throw UpdateException('${channel.name} 頻道尚未發佈更新資訊');
      }
      if (response.statusCode != 200) {
        throw const UpdateException('無法取得更新資訊，請稍後重試');
      }
      final found = AppRelease.fromJson(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
      if (found.channel != channel) {
        throw const FormatException('Manifest channel mismatch');
      }
      release = found;
      checkedAt = _now();
    } on UpdateException catch (e) {
      error = e.message;
    } on FormatException {
      error = '更新資訊格式錯誤，請稍後重試';
    } on TypeError {
      error = '更新資訊格式錯誤，請稍後重試';
    } catch (_) {
      error = '檢查更新失敗，請確認網路後重試';
    } finally {
      checking = false;
      _emit();
    }
  }

  Future<void> install() async {
    final download = asset;
    if (busy ||
        _disposed ||
        !updateAvailable ||
        download == null ||
        !supported) {
      return;
    }
    installing = true;
    error = null;
    message = null;
    progress = null;
    _emit();
    try {
      if (platform == TargetPlatform.android) {
        await _installApk(download, (value) {
          progress = value;
          _emit();
        });
        message = '已開啟 APK 安裝器，請完成系統安裝確認';
      } else {
        final installerUrl = iosInstaller.installUri(
          download.url,
          customTemplate: customIosInstaller,
        );
        var opened = false;
        try {
          opened = await _openUrl(installerUrl);
        } catch (_) {
          // An unavailable sideloading app falls back to the IPA download.
        }
        if (!opened && installerUrl != download.url) {
          opened = await _openUrl(download.url);
          if (opened) message = '未能開啟安裝工具，已改用瀏覽器下載 IPA';
        }
        if (!opened) throw const UpdateException('無法開啟下載連結，請複製連結後重試');
        message ??= installerUrl == download.url
            ? '已開啟 IPA 下載，請匯入你的簽署／側載工具'
            : '已交給 ${iosInstaller.label}，請在該工具完成安裝';
      }
    } on UpdateException catch (e) {
      error = e.message;
    } on PlatformException catch (e) {
      error = e.code == 'install_permission_denied'
          ? '尚未允許安裝未知來源 App，請重新安裝並允許權限'
          : '無法開啟 APK 安裝器，請重試或使用瀏覽器下載';
    } catch (_) {
      error = '更新下載或安裝失敗，請重試或使用瀏覽器下載';
    } finally {
      installing = false;
      progress = null;
      _emit();
    }
  }

  Future<void> openDownload({bool releaseNotes = false}) async {
    try {
      if (!await _openUrl(
        releaseNotes
            ? (release?.pageUrl ?? releasePage)
            : (asset?.url ?? releasePage),
      )) {
        throw const UpdateException('無法開啟連結');
      }
    } catch (_) {
      error = '無法開啟連結，請複製下載連結後重試';
      _emit();
    }
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _client.close();
    super.dispose();
  }
}
