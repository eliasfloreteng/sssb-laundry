package se.floreteng.sssblaundry.push

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.text.format.DateUtils
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import se.floreteng.sssblaundry.MainActivity
import se.floreteng.sssblaundry.R
import se.floreteng.sssblaundry.data.LaundryTime
import se.floreteng.sssblaundry.data.LeadUnit
import se.floreteng.sssblaundry.data.NotificationWording
import se.floreteng.sssblaundry.data.PushKind
import se.floreteng.sssblaundry.data.PushMessage
import se.floreteng.sssblaundry.data.PushTitle
import java.time.Duration
import java.time.Instant
import java.util.Formatter

/** Posts and takes down the booking notifications the server's pushes describe. */
class BookingNotifier(private val context: Context) {
    private val manager = NotificationManagerCompat.from(context)

    /**
     * Created up front and again before each post: re-creating a channel only
     * renames it, which is how its name follows a change of language.
     */
    fun createChannels() {
        manager.createNotificationChannelsCompat(
            listOf(
                channel(CHANNEL_REMINDERS, NotificationManagerCompat.IMPORTANCE_HIGH, R.string.channel_reminders, R.string.channel_reminders_description),
                // A dibs can come through minutes before the start, with the same
                // 15 minutes to tag in that a reminder warns about — iOS sends both
                // as time-sensitive.
                channel(CHANNEL_DIBS, NotificationManagerCompat.IMPORTANCE_HIGH, R.string.channel_dibs, R.string.channel_dibs_description),
                channel(CHANNEL_BOOKINGS, NotificationManagerCompat.IMPORTANCE_DEFAULT, R.string.channel_bookings, R.string.channel_bookings_description),
            ),
        )
    }

    fun show(message: PushMessage, now: Instant = Instant.now()) {
        if (message.kind == PushKind.Cancelled) {
            remove(message)
            return
        }
        if (!canPost()) return
        // Never let a reminder outlive the moment the booking is released, nor
        // anything else outlive the booking — the same limits the server's
        // time-to-live sets, so a late delivery is dropped rather than shown.
        val expiresAt = when (message.kind) {
            PushKind.Reminder -> message.start.plus(GRACE)
            else -> message.end ?: message.start.plus(GRACE)
        }
        val timeout = Duration.between(now, expiresAt)
        if (timeout.isNegative || timeout.isZero) return

        createChannels()
        val wording = ResourceWording(context)
        val body = message.body(wording)
        val notification = NotificationCompat.Builder(context, channelFor(message.kind))
            .setSmallIcon(R.drawable.ic_laundry)
            .setColor(ContextCompat.getColor(context, R.color.brand_blue))
            .setContentTitle(message.title(wording))
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setCategory(if (message.kind == PushKind.Reminder) NotificationCompat.CATEGORY_REMINDER else NotificationCompat.CATEGORY_EVENT)
            .setPriority(
                if (message.kind == PushKind.NewBooking) NotificationCompat.PRIORITY_DEFAULT else NotificationCompat.PRIORITY_HIGH,
            )
            .setTimeoutAfter(timeout.toMillis())
            .setContentIntent(openApp(message.tag))
            .setAutoCancel(true)
            .build()
        @Suppress("MissingPermission") // canPost() checked it.
        manager.notify(message.tag, NOTIFICATION_ID, notification)
    }

    /** A booking that no longer exists takes whatever was shown for it down with it. */
    fun remove(message: PushMessage) {
        manager.cancel(message.tag, NOTIFICATION_ID)
    }

    private fun canPost(): Boolean = manager.areNotificationsEnabled() &&
        (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)

    private fun openApp(tag: String): PendingIntent = PendingIntent.getActivity(
        context,
        tag.hashCode(),
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun channel(id: String, importance: Int, name: Int, description: Int) =
        NotificationChannelCompat.Builder(id, importance)
            .setName(context.getString(name))
            .setDescription(context.getString(description))
            .build()

    private fun channelFor(kind: PushKind) = when (kind) {
        PushKind.Reminder -> CHANNEL_REMINDERS
        PushKind.DibsWon -> CHANNEL_DIBS
        PushKind.NewBooking, PushKind.Cancelled -> CHANNEL_BOOKINGS
    }

    private companion object {
        const val CHANNEL_REMINDERS = "reminders"
        const val CHANNEL_BOOKINGS = "bookings"
        const val CHANNEL_DIBS = "dibs"
        /** Fixed: the tag is what tells one booking's notification from another's. */
        const val NOTIFICATION_ID = 1
        /** A session not tagged into within 15 minutes of its start is released. */
        val GRACE: Duration = Duration.ofMinutes(15)
    }
}

/**
 * The words from resources, the times in Stockholm time and the phone's
 * language and 12/24-hour preference — never strings from the server.
 */
private class ResourceWording(private val context: Context) : NotificationWording {
    private val res = context.resources
    private val zone = LaundryTime.stockholm.id

    override fun title(title: PushTitle): String = when (title) {
        PushTitle.StartsNow -> res.getString(R.string.notification_title_starts_now)
        is PushTitle.StartsIn -> res.getQuantityString(
            when (title.lead.unit) {
                LeadUnit.Minute -> R.plurals.notification_title_in_minutes
                LeadUnit.Hour -> R.plurals.notification_title_in_hours
                LeadUnit.Day -> R.plurals.notification_title_in_days
                LeadUnit.Week -> R.plurals.notification_title_in_weeks
            },
            title.lead.count,
            title.lead.count,
        )
        PushTitle.NewBooking -> res.getString(R.string.notification_title_new_booking)
        PushTitle.DibsWon -> res.getString(R.string.notification_title_dibs_won)
        is PushTitle.DibsSwapped -> res.getString(
            R.string.notification_title_dibs_swapped,
            format(title.replacedStart, title.replacedStart),
        )
    }

    /** "Tue, 4 Nov, 19:00–22:00"; a session past midnight names both days. */
    override fun span(start: Instant, end: Instant?): String = format(start, end ?: start)

    override fun withMachines(span: String, machines: String): String =
        res.getString(R.string.notification_body_machines, span, machines)

    override val activateWarning: String get() = res.getString(R.string.notification_activate)

    private fun format(start: Instant, end: Instant): String = DateUtils.formatDateRange(
        context,
        Formatter(StringBuilder(), res.configuration.locales[0]),
        start.toEpochMilli(),
        end.toEpochMilli(),
        DateUtils.FORMAT_SHOW_WEEKDAY or DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME or
            DateUtils.FORMAT_ABBREV_ALL or DateUtils.FORMAT_NO_YEAR,
        zone,
    ).toString()
}
