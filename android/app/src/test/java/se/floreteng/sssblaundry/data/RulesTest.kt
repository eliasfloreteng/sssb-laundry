package se.floreteng.sssblaundry.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class InviteLinkTest {
    @Test
    fun readsTheNumberOutOfTheFragment() {
        assertEquals("1234-5678-901", InviteLink.objectIdFromUrl("https://sssb-laundry.eliasf.se/invite#1234-5678-901"))
    }

    @Test
    fun ignoresOtherHostsAndPaths() {
        assertNull(InviteLink.objectIdFromUrl("https://example.com/invite#1234-5678-901"))
        assertNull(InviteLink.objectIdFromUrl("https://sssb-laundry.eliasf.se/other#1234-5678-901"))
        assertNull(InviteLink.objectIdFromUrl("https://sssb-laundry.eliasf.se/invite"))
    }

    @Test
    fun theHyphenInTheHostNeverConfusesThePastedNumber() {
        assertEquals("1234-5678-901", InviteLink.objectIdFromPasted("https://sssb-laundry.eliasf.se/invite#1234-5678-901"))
        assertEquals("1234-5678-901", InviteLink.objectIdFromPasted("  1234-5678-901\n"))
        assertNull(InviteLink.objectIdFromPasted("12345-678-901"))
        assertNull(InviteLink.objectIdFromPasted("hello"))
    }

    @Test
    fun sharesTheNumberInTheFragmentOnly() {
        assertEquals("https://sssb-laundry.eliasf.se/invite#1234-5678-901", InviteLink.url("1234-5678-901"))
        assertEquals("https://sssb-laundry.eliasf.se", InviteLink.url(null))
    }
}

class BookingRulesTest {
    private fun slot(start: String, startTime: String = "07:00", vararg groups: TimeslotGroup) = Timeslot(
        id = "x",
        startAt = start,
        endAt = start,
        localDate = start.take(10),
        startTime = startTime,
        endTime = "11:00",
        spansMidnight = false,
        groups = groups.toList(),
    )

    private val now = Instant.parse("2026-10-31T12:00:00Z")

    @Test
    fun takenWinsOverStarted() {
        val group = TimeslotGroup(1, GroupStatus.Unavailable, canBook = false, canCancel = false)
        val ts = slot("2026-10-31T06:00:00Z", groups = arrayOf(group))
        assertEquals(GroupRestriction.Taken, group.restriction(ts, now))
    }

    @Test
    fun aFreeGroupPastTheLimitCanBeLinedUpFor() {
        val group = TimeslotGroup(1, GroupStatus.Bookable, canBook = false, canCancel = false)
        val ts = slot("2026-11-01T06:00:00.000Z", groups = arrayOf(group))
        assertEquals(GroupRestriction.NotBookable, group.restriction(ts, now))
        assertTrue(group.canCallDibs(ts, now))
    }

    @Test
    fun anUnreadableStartNeverBlocksABooking() {
        val ts = slot("not a date")
        assertFalse(ts.hasStarted(now))
    }

    @Test
    fun activeHoursWrapAroundMidnight() {
        val late = slot("2026-11-01T22:00:00Z", startTime = "23:00")
        val early = slot("2026-11-01T02:00:00Z", startTime = "03:00")
        val noon = slot("2026-11-01T11:00:00Z", startTime = "12:00")
        assertTrue(ActiveHours.includes(late, 22 * 60, 6 * 60))
        assertTrue(ActiveHours.includes(early, 22 * 60, 6 * 60))
        assertFalse(ActiveHours.includes(noon, 22 * 60, 6 * 60))
        // Equal ends are "no filter", not an empty range.
        assertTrue(ActiveHours.includes(noon, 6 * 60, 6 * 60))
    }

    @Test
    fun decodesAGroupWithNoLocation() {
        val json = """{"week":{"fromDate":"2026-10-26","toDate":"2026-11-01","timezone":"Europe/Stockholm"},
            "groups":[{"id":1,"location":null,"name":"Grupp 1"}],"timeslots":[]}"""
        val week = ApiClient.json.decodeFromString<WeekResponse>(json)
        assertEquals("", week.groups.single().place)
    }

    @Test
    fun decodesAnErrorEnvelope() {
        val json = """{"error":{"code":"DIBS_LIMIT","message":"Too many","details":{"limit":7}}}"""
        val error = ApiClient.json.decodeFromString<ApiErrorEnvelope>(json).error
        assertEquals("DIBS_LIMIT", error.code)
        assertEquals(7, error.limit)
    }

    @Test
    fun stockholmDaysCrossDst() {
        // Sweden leaves summer time on the last Sunday of October.
        assertEquals("2026-10-26", LaundryTime.addDays("2026-10-25", 1))
        assertEquals("2026-10-31", LaundryTime.today(Instant.parse("2026-10-30T23:30:00Z")))
    }
}
