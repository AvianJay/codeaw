package tw.avianjay.codeaw

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Shows the conversation armed by Dart (`codeaw/live_activity`) as an ongoing progress
 * notification while the app is in the background. A foreground service keeps the process,
 * and with it the bridge connection, alive so the notification stays current; Android 16
 * promotes it to a Live Update.
 *
 * The service starts as the activity stops: apps may only start foreground services while
 * they are, or have just been, visible.
 */
object LiveUpdates {
    const val NOTIFICATION_ID = 7402
    private const val CHANNEL_ID = "codeaw_live"

    /** What to show once the app is hidden; null when nothing is being tracked. */
    private var content: Map<*, *>? = null
    /** Kept for a service that is still starting when tracking ends. */
    private var last: Map<*, *>? = null
    private var hidden = false
    private var starting = false
    private var service: LiveUpdateService? = null

    fun support(context: Context): Map<String, Any?> = mapOf(
        "available" to true,
        "allowed" to canShow(context),
        "promoted" to if (Build.VERSION.SDK_INT >= 36) {
            context.getSystemService(NotificationManager::class.java).canPostPromotedNotifications()
        } else {
            null
        },
    )

    fun show(next: Map<*, *>?) {
        content = next
        if (next == null) {
            stop()
            return
        }
        last = next
        service?.let { post(it, next) }
    }

    fun onAppHidden(context: Context) {
        hidden = true
        if (service != null || starting || content == null || !canShow(context)) return
        try {
            ContextCompat.startForegroundService(context, Intent(context, LiveUpdateService::class.java))
            starting = true
        } catch (_: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException: the app no longer counted as visible.
        }
    }

    fun onAppVisible() {
        hidden = false
        stop()
    }

    /** The engine is going away, so nothing would keep the notification current. */
    fun clear() {
        content = null
        stop()
    }

    // A service that is still starting stops itself once it is in the foreground: stopping it
    // before then makes the system treat it as a broken startForegroundService() call.
    private fun stop() {
        service?.stopSelf()
    }

    /** Returns whether the service is still wanted. */
    internal fun attach(s: LiveUpdateService): Boolean {
        starting = false
        service = s
        return hidden && content != null
    }

    internal fun detach(s: LiveUpdateService) {
        starting = false
        if (service === s) service = null
    }

    internal fun notification(context: Context): Notification = build(context, content ?: last ?: emptyMap<String, Any?>())

    fun openSettings(context: Context) {
        val promotion = Build.VERSION.SDK_INT >= 36 && canShow(context) &&
            !context.getSystemService(NotificationManager::class.java).canPostPromotedNotifications()
        val action = if (promotion) Settings.ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS else Settings.ACTION_APP_NOTIFICATION_SETTINGS
        try {
            context.startActivity(Intent(action).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName))
        } catch (_: ActivityNotFoundException) {
            context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
        }
    }

    private fun canShow(context: Context): Boolean {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT < 26) return true
        val channel = context.getSystemService(NotificationManager::class.java).getNotificationChannel(CHANNEL_ID)
        return channel == null || channel.importance != NotificationManager.IMPORTANCE_NONE
    }

    private fun post(context: Context, c: Map<*, *>) {
        try {
            context.getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, build(context, c))
        } catch (_: SecurityException) {
            // Notifications were revoked while the service was running.
        }
    }

    private fun build(context: Context, c: Map<*, *>): Notification {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(CHANNEL_ID) == null) {
            // Live Updates need at least default importance; updates stay silent.
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "背景進度", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "切到背景時，持續顯示正在執行的對話"
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                },
            )
        }
        val phase = c["phase"] as? String
        val steps = (c["steps"] as? List<*>).orEmpty()
        val startedAt = (c["startedAt"] as? Number)?.toLong()
        val agent = c["agent"] as? String
        val detail = c["detail"] as? String
        val link = c["link"] as? String
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_codeaw)
            .setColor(0xFF0F9D8A.toInt())
            .setContentTitle((c["title"] as? String)?.takeIf { it.isNotEmpty() } ?: agent ?: "codeaw")
            .setContentText(detail)
            .setSubText(agent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setRequestPromotedOngoing(true)
        when {
            // One segment per plan entry; long plans would leave only slivers.
            steps.isNotEmpty() -> builder.setStyle(
                NotificationCompat.ProgressStyle()
                    .setProgressSegments(
                        if (steps.size <= 12) steps.map { NotificationCompat.ProgressStyle.Segment(1) }
                        else listOf(NotificationCompat.ProgressStyle.Segment(steps.size)),
                    )
                    .setProgress(steps.count { it == "completed" }),
            )
            phase == "running" -> builder.setStyle(NotificationCompat.ProgressStyle().setProgressIndeterminate(true))
            else -> builder.setStyle(NotificationCompat.BigTextStyle().bigText(detail))
        }
        // The status bar chip shows this text, or else the elapsed time.
        when (phase) {
            "approval" -> builder.setShortCriticalText("待批准")
            "offline" -> builder.setShortCriticalText("離線")
        }
        if (startedAt != null) {
            builder.setWhen(startedAt).setShowWhen(true).setUsesChronometer(true)
        } else {
            builder.setShowWhen(false)
        }
        if (link != null) {
            val open = Intent(Intent.ACTION_VIEW, Uri.parse(link), context, MainActivity::class.java)
            builder.setContentIntent(
                PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
        }
        return builder.build()
    }
}

/** Keeps the process, and so the bridge connection, alive while [LiveUpdates] is shown. */
class LiveUpdateService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            ServiceCompat.startForeground(
                this,
                LiveUpdates.NOTIFICATION_ID,
                LiveUpdates.notification(this),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } catch (_: RuntimeException) {
            // Not allowed after all, e.g. the daily dataSync time is used up.
            stopSelf()
            return START_NOT_STICKY
        }
        if (!LiveUpdates.attach(this)) stopSelf()
        return START_NOT_STICKY
    }

    // Android 15 limits dataSync services to six hours a day.
    override fun onTimeout(startId: Int, fgsType: Int) = stopSelf()

    override fun onDestroy() {
        LiveUpdates.detach(this)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
