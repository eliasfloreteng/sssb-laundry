package se.floreteng.sssblaundry.update

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.core.net.toUri
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import se.floreteng.sssblaundry.BuildConfig
import se.floreteng.sssblaundry.data.AndroidRelease
import se.floreteng.sssblaundry.data.ApiClient
import se.floreteng.sssblaundry.data.Config
import kotlin.coroutines.cancellation.CancellationException

/**
 * Tells an install made from the APK that a newer one is out. Play keeps its own
 * installs up to date, and an app from Play may not update itself any other way,
 * so this only looks when something else installed it: a browser, Files, adb.
 *
 * It does not install anything itself — that takes REQUEST_INSTALL_PACKAGES,
 * which Play does not allow an app like this. The download opens in the browser
 * instead, which the user already let install apps the first time round.
 */
class AppUpdater(
    private val context: Context,
    private val api: ApiClient,
    private val scope: CoroutineScope,
) {
    private val _available = MutableStateFlow<AndroidRelease?>(null)

    /** A release newer than this build, once a check has found one. */
    val available: StateFlow<AndroidRelease?> = _available.asStateFlow()

    /** A debug build is signed with another key, so the release APK could not replace it anyway. */
    private val isEnabled: Boolean by lazy { !BuildConfig.DEBUG && installer() != PLAY_STORE }

    private var lastChecked = 0L
    private var checking: Job? = null

    /** On every return to the app, at most every few hours: a release is rarely more than daily. */
    fun check() {
        if (!isEnabled || checking?.isActive == true) return
        if (lastChecked != 0L && SystemClock.elapsedRealtime() - lastChecked < CHECK_INTERVAL_MS) return
        checking = scope.launch {
            try {
                val latest = api.latestAndroidRelease()
                lastChecked = SystemClock.elapsedRealtime()
                _available.value = latest.takeIf { it.versionCode > BuildConfig.VERSION_CODE }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Offline, or the server is: the next return to the app tries again.
                Log.i(TAG, "Update check failed: ${e.message}")
            }
        }
    }

    /** Opens the newest APK in the browser, which downloads it and offers to install it. */
    fun download(from: Context) {
        val intent = Intent(Intent.ACTION_VIEW, DOWNLOAD_URL.toUri()).addCategory(Intent.CATEGORY_BROWSABLE)
        try {
            from.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "No browser to download the update with")
        }
    }

    private fun installer(): String? = try {
        val pm = context.packageManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            pm.getInstallSourceInfo(context.packageName).installingPackageName
        } else {
            @Suppress("DEPRECATION")
            pm.getInstallerPackageName(context.packageName)
        }
    } catch (e: PackageManager.NameNotFoundException) {
        null
    }

    companion object {
        private const val TAG = "AppUpdater"
        private const val PLAY_STORE = "com.android.vending"
        private const val CHECK_INTERVAL_MS = 4 * 60 * 60 * 1000L
        const val DOWNLOAD_URL = "${Config.BASE_URL}/android/download"
    }
}
