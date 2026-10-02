package com.allways.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val updaterChannel = "com.allways.app/apk_installer"
    private val installAction = "com.allways.app.PACKAGE_INSTALL_STATUS"
    private val notificationChannelId = "allways_updates"

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updaterChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "showNotification" -> {
                        showLocalNotification(call.argument<String>("title") ?: "ALLways", call.argument<String>("body") ?: "New update")
                        result.success("shown")
                    }
                    "createNotificationChannel" -> {
                        createNotificationChannel()
                        result.success("created")
                    }
                    "installApk" -> installApk(call.argument<String>("path"), result)
                    "openInstallSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                        } else {
                            startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
                        }
                        result.success("opened")
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(
                NotificationChannel(notificationChannelId, "ALLways Updates", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Order, delivery and ALLways alerts"
                    enableVibration(true)
                }
            )
        }
    }

    private fun showLocalNotification(title: String, body: String) {
        createNotificationChannel()
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                (System.currentTimeMillis() and 0x7fffffff).toInt(),
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
            )
        }
        val notification = NotificationCompat.Builder(this, notificationChannelId)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pending)
            .build()
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify((System.currentTimeMillis() and 0x7fffffff).toInt(), notification)
    }

    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("NO_APK", "APK path is missing", null)
            return
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()) {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName")
                    )
                )
                result.success("permission_required")
                return
            }
            val apk = File(path)
            if (!apk.exists() || !apk.isFile || !apk.canRead() || apk.length() <= 0L) {
                result.error("NO_APK", "Downloaded APK is missing or unreadable", null)
                return
            }

            val installer = packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL
            )
            params.setAppPackageName(packageName)
            params.setAppLabel("ALLways")

            val sessionId = installer.createSession(params)
            val session = installer.openSession(sessionId)
            try {
                session.openWrite("package", 0, apk.length()).use { output ->
                    FileInputStream(apk).use { input ->
                        input.copyTo(output, 1024 * 1024)
                    }
                    session.fsync(output)
                }

                val statusIntent = Intent(this, InstallStatusReceiver::class.java).apply {
                    action = installAction
                    putExtra("sessionId", sessionId)
                }

                val flags =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                    } else {
                        PendingIntent.FLAG_UPDATE_CURRENT
                    }

                session.commit(
                    PendingIntent.getBroadcast(
                        this,
                        sessionId,
                        statusIntent,
                        flags
                    ).intentSender
                )
                result.success("started")
            } catch (e: Exception) {
                try { session.abandon() } catch (_: Exception) {}
                throw e
            } finally {
                try { session.close() } catch (_: Exception) {}
            }
        } catch (e: Exception) {
            result.error(
                "INSTALL_FAILED",
                e.message ?: "Package installation failed",
                null
            )
        }
    }

    class InstallStatusReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (
                intent.getIntExtra(
                    PackageInstaller.EXTRA_STATUS,
                    PackageInstaller.STATUS_FAILURE
                ) == PackageInstaller.STATUS_PENDING_USER_ACTION
            ) {
                val confirmIntent =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(
                            Intent.EXTRA_INTENT,
                            Intent::class.java
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(Intent.EXTRA_INTENT)
                    }

                if (confirmIntent != null) {
                    confirmIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    context.startActivity(confirmIntent)
                }
            }
        }
    }
}

