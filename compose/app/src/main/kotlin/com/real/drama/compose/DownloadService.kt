package com.real.drama.compose

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager
import kotlinx.coroutines.*

class DownloadService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var job: Job? = null
    private var wake: PowerManager.WakeLock? = null
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("downloads", "下载与媒体处理", NotificationManager.IMPORTANCE_LOW))
        startForeground(21, notification("正在准备下载"))
        wake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "RealDrama:downloads").apply { setReferenceCounted(false); acquire(10 * 60 * 1000L) }
    }
    private fun notification(text: String): Notification {
        val intent = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, "downloads").setSmallIcon(android.R.drawable.stat_sys_download).setContentTitle("RealDrama")
            .setContentText(text).setContentIntent(intent).setOngoing(true).build()
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (job?.isActive != true) job = scope.launch {
            val repository = (application as DramaApplication).repository
            var idle = 0
            val attempted = mutableSetOf<String>()
            try {
                repository.open(); check(repository.ready.value) { "本地配置未就绪" }
                while (isActive && idle < 5) {
                    val jobs = NativeBridge.call(obj("action" to "downloads")).array("jobs").objects()
                    wake?.acquire(10 * 60 * 1000L)
                    if (repository.store.canDownload && repository.store.bool("autoExport", global = true)) {
                        val pending = jobs.firstOrNull { it.text("state") == "completed" && !repository.mediaLibrary.automaticSkipped(it.text("id")) && repository.store.allowed(it.getJSONObject("drama").text("source")) && "${it.text("id")}:${MediaLibrary.version(it)}" !in attempted && repository.mediaLibrary.media.value.none { item -> item.text("jobId") == it.text("id") && item.text("sourceVersion") == MediaLibrary.version(it) && repository.mediaLibrary.fileFor(item).isFile } }
                        if (pending != null) {
                            attempted.add("${pending.text("id")}:${MediaLibrary.version(pending)}")
                            try { repository.mediaLibrary.exportEpisode(pending) } catch (cancel: CancellationException) { throw cancel } catch (error: Exception) { repository.diagnostics.record("media_export_error", obj("code" to "export_failed", "exceptionType" to error.javaClass.simpleName)) }
                            idle = 0; continue
                        }
                    }
                    val running = jobs.count { it.text("state") in setOf("queued", "downloading") } + repository.mediaLibrary.jobs.value.count { it.text("state") in setOf("queued", "running") } + if (repository.mediaLibrary.status.value.isNotEmpty()) 1 else 0
                    if (running == 0) idle++ else idle = 0
                    getSystemService(NotificationManager::class.java).notify(21, notification("$running 个任务进行中"))
                    delay(3000)
                }
            } catch (cancel: CancellationException) { throw cancel } catch (error: Exception) { repository.diagnostics.record("download_service_error", obj("exceptionType" to error.javaClass.simpleName)) } finally { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
        }
        return START_NOT_STICKY
    }
    override fun onTimeout(startId: Int, fgsType: Int) {
        val application = application as DramaApplication
        application.scope.launch(NonCancellable) {
            try {
                job?.cancelAndJoin()
                val repo = application.repository
                repo.mediaLibrary.pause()
                NativeBridge.call(obj("action" to "downloads")).array("jobs").objects().filter { it.text("state") in setOf("queued", "downloading") }.forEach { NativeBridge.call(obj("action" to "controlDownloads", "command" to "pause", "jobId" to it.text("id"))) }
            } finally { stopForeground(STOP_FOREGROUND_REMOVE); stopSelf() }
        }
    }
    override fun onDestroy() { if (wake?.isHeld == true) wake?.release(); scope.cancel(); super.onDestroy() }
    companion object { fun start(context: Context) { context.startForegroundService(Intent(context, DownloadService::class.java)) } }
}
