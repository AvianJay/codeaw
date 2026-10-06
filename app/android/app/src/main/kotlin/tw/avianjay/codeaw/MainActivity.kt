package tw.avianjay.codeaw

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : FlutterActivity() {
    private var permissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "codeaw/app_updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestInstallPermission" -> requestInstallPermission(result)
                    "installApk" -> installApk(call.argument<String>("path"), result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "codeaw/live_activity")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "support" -> result.success(LiveUpdates.support(this))
                    "show" -> {
                        LiveUpdates.show(call.arguments as? Map<*, *>)
                        result.success(null)
                    }
                    "openSettings" -> {
                        LiveUpdates.openSettings(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onStart() {
        super.onStart()
        LiveUpdates.onAppVisible()
    }

    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations) LiveUpdates.onAppHidden(applicationContext)
    }

    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

    private fun requestInstallPermission(result: MethodChannel.Result) {
        if (canInstallPackages()) {
            result.success(null)
            return
        }
        if (permissionResult != null) {
            result.error("install_permission_pending", "Permission request already open", null)
            return
        }
        permissionResult = result
        try {
            startActivityForResult(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")),
                INSTALL_PERMISSION_REQUEST
            )
        } catch (_: ActivityNotFoundException) {
            permissionResult = null
            result.error("installer_unavailable", "Install permission settings unavailable", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != INSTALL_PERMISSION_REQUEST) return
        val result = permissionResult ?: return
        permissionResult = null
        if (canInstallPackages()) result.success(null)
        else result.error("install_permission_denied", "Allow installing unknown apps to continue", null)
    }

    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (!canInstallPackages()) {
            result.error("install_permission_denied", "Install permission required", null)
            return
        }
        try {
            val file = path?.let { File(it).canonicalFile }
            val directory = File(cacheDir, "updates").canonicalFile
            if (file == null || file.parentFile != directory || !file.isFile || file.extension != "apk") {
                result.error("invalid_apk", "APK must be in the private update cache", null)
                return
            }
            val archive = packageManager.getPackageArchiveInfo(file.path, 0)
            if (archive?.packageName != packageName) {
                result.error("invalid_apk", "APK belongs to another application", null)
                return
            }
            val uri = FileProvider.getUriForFile(this, "$packageName.app_updates", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                clipData = ClipData.newRawUri("APK update", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            result.success(null)
        } catch (_: Exception) {
            result.error("installer_unavailable", "Could not open APK installer", null)
        }
    }

    override fun onDestroy() {
        permissionResult?.error("installer_unavailable", "Activity closed", null)
        permissionResult = null
        // The Flutter engine goes with the activity; nothing would update the notification.
        LiveUpdates.clear()
        super.onDestroy()
    }

    companion object {
        private const val INSTALL_PERMISSION_REQUEST = 7401
    }
}
