package se.floreteng.sssblaundry

import android.app.Application
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.MainScope
import se.floreteng.sssblaundry.data.ApiClient
import se.floreteng.sssblaundry.data.SettingsRepository

class SssbLaundryApplication : Application() {
    /** Lives as long as the process: settings are read once and shared by every screen. */
    val appScope: CoroutineScope = MainScope()

    lateinit var settings: SettingsRepository
        private set

    lateinit var api: ApiClient
        private set

    override fun onCreate() {
        super.onCreate()
        settings = SettingsRepository(this, appScope)
        api = ApiClient(objectId = { settings.current.objectId.ifEmpty { null } })
    }
}
