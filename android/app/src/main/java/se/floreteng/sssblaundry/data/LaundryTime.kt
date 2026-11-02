package se.floreteng.sssblaundry.data

import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.time.format.FormatStyle
import java.util.Locale

/**
 * Europe/Stockholm, always. Portal dates arrive without a timezone, timeslots can
 * span midnight, and DST is real — falling back to the device's zone skips or
 * duplicates days.
 */
object LaundryTime {
    val stockholm: ZoneId = ZoneId.of("Europe/Stockholm")

    fun today(now: Instant = Instant.now()): String = LocalDate.ofInstant(now, stockholm).toString()

    fun addDays(day: String, days: Long): String? =
        runCatching { LocalDate.parse(day).plusDays(days).toString() }.getOrNull()

    /** `startAt`/`endAt` may or may not carry fractional seconds; ISO parsing takes both. */
    fun parseInstant(value: String): Instant? = try {
        OffsetDateTime.parse(value).toInstant()
    } catch (_: DateTimeParseException) {
        runCatching { Instant.parse(value) }.getOrNull()
    }

    /** Midnight in Stockholm on that day, as epoch millis — what the date picker deals in. */
    fun epochMillis(day: String): Long? =
        runCatching { LocalDate.parse(day).atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toEpochMilli() }.getOrNull()

    /** The date picker hands back UTC midnight of the picked day. */
    fun dayFromPickerMillis(millis: Long): String =
        Instant.ofEpochMilli(millis).atZone(java.time.ZoneOffset.UTC).toLocalDate().toString()

    /** "Monday 1 Sep" / "måndag 1 sep." — fields fixed, order the locale's business. */
    fun dayLabel(day: String, locale: Locale = Locale.getDefault()): String {
        val date = runCatching { LocalDate.parse(day) }.getOrNull() ?: return day
        val pattern = android.text.format.DateFormat.getBestDateTimePattern(locale, "EEEEdMMM")
        return date.format(DateTimeFormatter.ofPattern(pattern, locale))
    }

    fun clockTime(instant: Instant, locale: Locale = Locale.getDefault()): String =
        ZonedDateTime.ofInstant(instant, stockholm)
            .format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale))

    /** "HH:mm" → minutes since midnight. */
    fun minutes(timeString: String): Int? {
        val parts = timeString.split(":")
        if (parts.size < 2) return null
        val h = parts[0].toIntOrNull() ?: return null
        val m = parts[1].toIntOrNull() ?: return null
        return h * 60 + m
    }
}

val Timeslot.start: Instant? get() = LaundryTime.parseInstant(startAt)
val Timeslot.end: Instant? get() = LaundryTime.parseInstant(endAt)

/** "07:00 – 11:00", the way the row and the sheet both show it. */
val Timeslot.timeRange: String get() = "$startTime – $endTime"

/** Day and time on one line: what the clipboard gets. */
val Timeslot.dayAndTime: String get() = "${LaundryTime.dayLabel(localDate)}, $timeRange"
