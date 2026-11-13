package xyz.vidur.pux.system

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import xyz.vidur.pux.MainActivity

/**
 * Clears all application user data and restarts enrollment (same UID, no extra permission).
 */
object AppDataReset {

    fun resetAndRestart(activity: Activity) {
        val am = activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        if (am.clearApplicationUserData()) {
            return
        }
        val launch = Intent(activity, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        }
        activity.startActivity(launch)
        activity.finishAffinity()
        Runtime.getRuntime().exit(0)
    }
}
