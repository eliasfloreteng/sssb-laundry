package se.floreteng.sssblaundry

import android.app.Application
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.MainScope
import se.floreteng.sssblaundry.data.ApiClient
import se.floreteng.sssblaundry.data.SettingsRepository
import se.floreteng.sssblaundry.push.BookingNotifier
import se.floreteng.sssblaundry.push.PushRegistrar
import se.floreteng.sssblaundry.update.AppUpdater

class SssbLaundryApplication : Application() {
    /** Lives as long as the process: settings are read once and shared by every screen. */
    val appScope: CoroutineScope = MainScope()

    lateinit var settings: SettingsRepository
        private set

    lateinit var api: ApiClient
        private set

    lateinit var push: PushRegistrar
        private set

    lateinit var notifier: BookingNotifier
        private set

    lateinit var updater: AppUpdater
        private set

    override fun onCreate() {
        super.onCreate()
        settings = SettingsRepository(this, appScope)
        api = ApiClient(
            objectId = { settings.current.objectId.ifEmpty { null } },
            deviceToken = { settings.current.deviceToken },
        )
        notifier = BookingNotifier(this).also { it.createChannels() }
        push = PushRegistrar(this, settings, api, appScope).also { it.start() }
        updater = AppUpdater(this, api, appScope)
    }
}
