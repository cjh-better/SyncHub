package xyz.synchub.android.sync

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import xyz.synchub.android.util.L
import xyz.synchub.android.util.NativePrefs

/**
 * 看门狗：每 15 分钟检查一次同步服务是否还活着，被系统 / 厂商省电策略杀掉后自动拉起，
 * 并检查服务内的共享 FlutterEngine 与剪贴板来源是否正常（[SyncService.healthCheck]）。
 */
class Watchdog : JobService() {
    override fun onStartJob(params: JobParameters?): Boolean {
        val p = NativePrefs.get(this)
        if (p.isConfigured && p.serviceEnabled) {
            val s = SyncService.instance
            if (s == null) {
                L.w("看门狗：同步服务未运行（可能被系统杀掉），正在重新启动")
                SyncService.start(this, reason = "看门狗")
            } else {
                s.healthCheck()
            }
        }
        return false
    }

    override fun onStopJob(params: JobParameters?): Boolean = false

    companion object {
        private const val JOB_ID = 4201

        fun schedule(ctx: Context) {
            runCatching {
                val js = ctx.getSystemService(JobScheduler::class.java)
                if (js.getPendingJob(JOB_ID) != null) return
                js.schedule(
                    JobInfo.Builder(JOB_ID, ComponentName(ctx, Watchdog::class.java))
                        .setPeriodic(15 * 60 * 1000L)
                        .setPersisted(true)
                        .build(),
                )
            }.onFailure { L.w("看门狗调度失败", it) }
        }

        fun cancel(ctx: Context) {
            runCatching { ctx.getSystemService(JobScheduler::class.java).cancel(JOB_ID) }
        }
    }
}
