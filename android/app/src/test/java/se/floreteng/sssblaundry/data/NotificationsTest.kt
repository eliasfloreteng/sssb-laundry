package se.floreteng.sssblaundry.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** The same choices `leadUnit`, `reminderTitle`, `dibsWonTitle` and `bodyAlert` make on the server. */
class LeadUnitTest {
    @Test
    fun picksTheLargestUnitThatDividesExactly() {
        assertEquals(Lead(5, LeadUnit.Minute), leadUnit(5))
        assertEquals(Lead(90, LeadUnit.Minute), leadUnit(90))
        assertEquals(Lead(1, LeadUnit.Hour), leadUnit(60))
        assertEquals(Lead(2, LeadUnit.Hour), leadUnit(120))
        assertEquals(Lead(36, LeadUnit.Hour), leadUnit(2160))
        assertEquals(Lead(1, LeadUnit.Day), leadUnit(1440))
        assertEquals(Lead(3, LeadUnit.Day), leadUnit(4320))
        assertEquals(Lead(1, LeadUnit.Week), leadUnit(10080))
        assertEquals(Lead(2, LeadUnit.Week), leadUnit(20160))
    }

    @Test
    fun alertsMatchTheIosOptionsAndTheServersMinutes() {
        assertEquals(
            listOf(-1, 0, 5, 10, 15, 30, 60, 120, 1440, 10080),
            BookingAlert.entries.map { it.minutes },
        )
        assertNull(BookingAlert.Off.minutesBefore)
        assertEquals(0, BookingAlert.AtStart.minutesBefore)
        assertNull(BookingAlert.AtStart.lead)
        assertEquals(Lead(1, LeadUnit.Week), BookingAlert.OneWeek.lead)
        assertEquals(BookingAlert.TwoHours, BookingAlert.of(120, BookingAlert.Off))
        assertEquals(BookingAlert.TenMinutes, BookingAlert.of(7, BookingAlert.TenMinutes))
        assertEquals(BookingAlert.TenMinutes, BookingAlert.of(null, BookingAlert.TenMinutes))
    }
}

class PushMessageTest {
    private val start = "2026-11-04T19:00:00.000+01:00"
    private val end = "2026-11-04T22:00:00.000+01:00"

    private fun message(kind: String, vararg extra: Pair<String, String>) = PushMessage.parse(
        mapOf(
            "kind" to kind,
            "timeslotId" to "abc",
            "startAt" to start,
            "endAt" to end,
            "groupIds" to "12,13",
            "machines" to "Tvättstuga 1, Tvättstuga 2",
            "location" to "",
        ) + extra,
    )!!

    /** English, fixed format and zone, so the assertions don't depend on the machine running them. */
    private val wording = object : NotificationWording {
        private val day = DateTimeFormatter.ofPattern("EEE d MMM", Locale.ENGLISH).withZone(ZoneId.of("Europe/Stockholm"))
        private val time = DateTimeFormatter.ofPattern("HH:mm", Locale.ENGLISH).withZone(ZoneId.of("Europe/Stockholm"))

        override fun title(title: PushTitle) = when (title) {
            PushTitle.StartsNow -> "Laundry starts now"
            is PushTitle.StartsIn -> {
                val unit = title.lead.unit.name.lowercase()
                "Laundry in ${title.lead.count} $unit${if (title.lead.count == 1) "" else "s"}"
            }
            PushTitle.NewBooking -> "New laundry booking"
            PushTitle.DibsWon -> "Dibs came through — it’s yours"
            is PushTitle.DibsSwapped -> "Dibs came through — gave up ${day.format(title.replacedStart)} ${time.format(title.replacedStart)}"
        }

        override fun span(start: Instant, end: Instant?) =
            "${day.format(start)} ${time.format(start)}–${end?.let(time::format).orEmpty()}"

        override fun withMachines(span: String, machines: String) = "$span · $machines"

        override val activateWarning = "Activate with your Aptus tag within 15 minutes or the session is released."
    }

    @Test
    fun parsesEveryField() {
        val push = message("dibs_won", "offsetMinutes" to "45", "replacedStartAt" to "2026-11-06T07:00:00+01:00")
        assertEquals(PushKind.DibsWon, push.kind)
        assertEquals(Instant.parse("2026-11-04T18:00:00Z"), push.start)
        assertEquals(Instant.parse("2026-11-04T21:00:00Z"), push.end)
        assertEquals(listOf(12, 13), push.groupIds)
        assertEquals("abc", push.timeslotId)
        assertEquals(45, push.offsetMinutes)
        assertEquals(Instant.parse("2026-11-06T06:00:00Z"), push.replacedStart)
    }

    @Test
    fun ignoresUnknownKindsAndMessagesWithoutAStart() {
        assertNull(PushMessage.parse(mapOf("kind" to "live_activity", "startAt" to start)))
        assertNull(PushMessage.parse(mapOf("kind" to "reminder")))
        assertNull(PushMessage.parse(mapOf("kind" to "reminder", "startAt" to "tomorrow")))
    }

    @Test
    fun aCancellationNeedsOnlyItsStart() {
        val push = PushMessage.parse(mapOf("kind" to "cancelled", "startAt" to start, "endAt" to end, "groupIds" to "12"))!!
        assertEquals(PushKind.Cancelled, push.kind)
        assertEquals("", push.machines)
    }

    @Test
    fun everyPushAboutABookingSharesOneTag() {
        val tags = listOf(
            message("reminder", "offsetMinutes" to "10"),
            message("new_booking"),
            message("dibs_won", "offsetMinutes" to "5"),
            PushMessage.parse(mapOf("kind" to "cancelled", "startAt" to "2026-11-04T18:00:00Z"))!!,
        ).map { it.tag }.toSet()
        assertEquals(setOf("booking.${Instant.parse("2026-11-04T18:00:00Z").epochSecond}"), tags)
    }

    @Test
    fun reminderTitles() {
        assertEquals("Laundry starts now", message("reminder", "offsetMinutes" to "0").title(wording))
        assertEquals("Laundry starts now", message("reminder").title(wording))
        assertEquals("Laundry in 1 minute", message("reminder", "offsetMinutes" to "1").title(wording))
        assertEquals("Laundry in 10 minutes", message("reminder", "offsetMinutes" to "10").title(wording))
        assertEquals("Laundry in 1 hour", message("reminder", "offsetMinutes" to "60").title(wording))
        assertEquals("Laundry in 2 hours", message("reminder", "offsetMinutes" to "120").title(wording))
        assertEquals("Laundry in 1 day", message("reminder", "offsetMinutes" to "1440").title(wording))
        assertEquals("Laundry in 1 week", message("reminder", "offsetMinutes" to "10080").title(wording))
    }

    @Test
    fun otherTitles() {
        assertEquals("New laundry booking", message("new_booking").title(wording))
        assertEquals("Dibs came through — it’s yours", message("dibs_won", "offsetMinutes" to "300").title(wording))
        assertEquals(
            "Dibs came through — gave up Fri 6 Nov 07:00",
            message("dibs_won", "offsetMinutes" to "300", "replacedStartAt" to "2026-11-06T07:00:00+01:00").title(wording),
        )
    }

    @Test
    fun bodyIsTheTimeThenTheMachines() {
        assertEquals("Wed 4 Nov 19:00–22:00 · Tvättstuga 1, Tvättstuga 2", message("new_booking").body(wording))
        assertEquals("Wed 4 Nov 19:00–22:00", message("new_booking", "machines" to "").body(wording))
    }

    @Test
    fun theGracePeriodWarningComesWithin15MinutesOfTheStart() {
        val warning = "\nActivate with your Aptus tag within 15 minutes or the session is released."
        assertEquals("Wed 4 Nov 19:00–22:00 · Tvättstuga 1, Tvättstuga 2$warning", message("reminder", "offsetMinutes" to "15").body(wording))
        assertEquals("Wed 4 Nov 19:00–22:00$warning", message("reminder", "offsetMinutes" to "0", "machines" to "").body(wording))
        assertTrue(message("dibs_won", "offsetMinutes" to "3").warnsToActivate)
        assertFalse(message("reminder", "offsetMinutes" to "30").warnsToActivate)
        assertFalse(message("dibs_won", "offsetMinutes" to "120").warnsToActivate)
        // A new booking is news, not a nudge, however soon it starts.
        assertFalse(message("new_booking", "offsetMinutes" to "0").warnsToActivate)
    }
}
