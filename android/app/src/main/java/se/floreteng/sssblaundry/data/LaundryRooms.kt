package se.floreteng.sssblaundry.data

/**
 * The rules SSSB publishes per laundry room, mirrored from
 * <https://www.sssb.se/en/book-a-laundry-room/> (its dropdown is filled from
 * `wp-content/themes/sssb_pilot2/js/laundry.js`). Transcribed verbatim, SSSB's typos
 * included, exactly as the iOS app's LaundryRooms.swift — keep the two in step.
 * Nothing here is enforced: Aptus decides. An unset room shows no limits at all.
 */
data class LaundryRoom(
    /** The resident's street address, as SSSB lists it. */
    val address: String,
    /** Where the laundry room serving that address actually is. */
    val room: String,
    /** Future sessions that may be held at once; `null` is no maximum. */
    val maxFutureBookings: Int?,
    /** How long the tag still opens the room after a session has ended. */
    val minutesAfterBooking: Int,
    /** SSSB's "Max booking per week/month"; `null` is no maximum. */
    val quota: Quota?,
) {
    data class Quota(val count: Int, val period: Period)

    enum class Period { Week, Month }

    /** Two rooms serve the same Kungshamra address, so the address alone is not an id. */
    val id: String get() = "$address|$room"
}

object LaundryRooms {
    fun room(id: String?): LaundryRoom? = if (id.isNullOrEmpty()) null else all.firstOrNull { it.id == id }

    val all: List<LaundryRoom> = listOf(
        LaundryRoom("Amanuensvägen 1", "Forskarbacken 5 + 5 B", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Amanuensvägen 2", "Professorsslingan 15", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Amanuensvägen 3", "Forskarbacken 10", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Amanuensvägen 4", "Professorsslingan 15", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Amanuensvägen 5", "Forskarbacken 10", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Amanuensvägen 6", "Professorsslingan 15", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Amanuensvägen 8-14", "Professorsslingan 15", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Apelbergsgatan 54", "Apelsbergsgatan 54", 2, 60, null),
        LaundryRoom("Armégatan 32 A + 34", "Armégatan 32 A", 2, 60, null),
        LaundryRoom("Armégatan 32 B+C", "Armégatan 32 C", 2, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("David Bagares Gata 6", "David Bagares Gata 6", 2, 60, null),
        LaundryRoom("Drottninggatan 67", "Apelsbergsgatan 54", 2, 60, null),
        LaundryRoom("Edinsvägen 22 A+B", "Edinsvägen 22 A", 1, 60, null),
        LaundryRoom("Emmylundsvägen 1-3", "Emmylundsvägen 1", 1, 60, null),
        LaundryRoom("Emmylundsvägen 5", "Emmylundsvägen 5", 1, 70, null),
        LaundryRoom("Forskarbacken 10-12", "Forskarbacken 10", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Forskarbacken 11", "Forskarbacken 6", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Forskarbacken 13", "Forskarbacken 6", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Forskarbacken 1-3", "Forskarbacken 5 + 5 B", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Forskarbacken 15", "Forskarbacken 10, Professorsslingan 15", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Forskarbacken 15-19", "Forskarbacken 10", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Forskarbacken 21", "Professorsslingan 39", 2, 60, LaundryRoom.Quota(8, LaundryRoom.Period.Month)),
        LaundryRoom("Forskarbacken 4", "Forskarbacken 6", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Forskarbacken 5", "Forskarbacken 5 + 5 B", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Forskarbacken 6", "Forskarbacken 6", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Forskarbacken 7", "Forskarbacken 5 + 5 B", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Forskarbacken 8-9", "Forskarbacken 6", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Gustav III:s Boulevard 2", "Gustav III:s Boulevard 2", 1, 60, null),
        LaundryRoom("Gustav III:s Boulevard 4", "Gustav III:s Boulevard 4", 1, 60, null),
        LaundryRoom("Gärdesvägen 2-10", "Gärdesvägen 10", 1, 60, null),
        LaundryRoom("Holländargatan 21 B", "Holländargatan 21B", 2, 60, null),
        LaundryRoom("Kammakargatan 36 A", "Kammarmakargatan 36 A", null, 60, null),
        LaundryRoom("Kammakargatan 36 B", "Kammarmakargatan 36 B", null, 60, null),
        LaundryRoom("Kungshamra 11-46 och 51-76", "Kungshamra 1", 1, 60, LaundryRoom.Quota(2, LaundryRoom.Period.Week)),
        LaundryRoom("Kungshamra 11-46 och 51-76", "Kungshamra 12 C", 2, 60, LaundryRoom.Quota(3, LaundryRoom.Period.Week)),
        LaundryRoom("Kungshamra 11-46 och 51-76", "Kungshamra 43 C", 1, 60, null),
        LaundryRoom("Kungshamra 2", "Kungshamra 2", 1, 60, null),
        LaundryRoom("Kungshamra 3", "Kungshamra 3", 1, 60, null),
        LaundryRoom("Kungshamra 47", "Kungshamra 47", 1, 60, null),
        LaundryRoom("Kungshamra 48", "Kungshamra 48", 1, 60, null),
        LaundryRoom("Kungshamra 81", "Kungshamra 81", 1, 60, null),
        LaundryRoom("Kungshamra 82", "Kungshamra 82", 1, 60, null),
        LaundryRoom("Kungshamra 83", "Kungshamra 83", 1, 60, null),
        LaundryRoom("Körsbärsvägen 2-4", "Körsbärsvägen 4 B (K1)", 2, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Körsbärsvägen 3", "Körsbärsvägen 5", 1, 60, null),
        LaundryRoom("Körsbärsvägen 5", "Körsbärsvägen 5", 1, 60, null),
        LaundryRoom("Körsbärsvägen 9", "Körsbärsvägen 9", 1, 60, LaundryRoom.Quota(2, LaundryRoom.Period.Week)),
        LaundryRoom("Löjtnantsgatan 11-15", "Löjtnantsgatan 13", 1, 60, null),
        LaundryRoom("Maltgatan 12", "Maltgatan 12", 1, 60, null),
        LaundryRoom("Maltgatan 4", "Maltgatan 4", 1, 60, null),
        LaundryRoom("Maltgatan 8", "Maltgatan 8", 1, 60, null),
        LaundryRoom("Nathorsvägen 46", "Nathorsvägen 46", 1, 60, null),
        LaundryRoom("Norra Stationsgatan 97-109", "Norra Stationsgatan 99", 2, 60, null),
        LaundryRoom("Professorsslingan 9", "Professorsslingan 15", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Professorsslingan 10", "Professorsslingan 10", 2, 60, LaundryRoom.Quota(8, LaundryRoom.Period.Month)),
        LaundryRoom("Professorsslingan 11", "Professorsslingan 15", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Professorsslingan 13", "Professorsslingan 15", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Professorsslingan 15-19", "Professorsslingan 15", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Professorsslingan 21", "Professorsslingan 39", 2, 60, LaundryRoom.Quota(8, LaundryRoom.Period.Month)),
        LaundryRoom("Professorsslingan 23-25", "Professorsslingan 15", 1, 60, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Professorsslingan 31-45", "Professorsslingan 39", 2, 60, LaundryRoom.Quota(8, LaundryRoom.Period.Month)),
        LaundryRoom("Professorsslingan 47-49", "Professorsslingan 49", 2, 0, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Professorsslingan 51-53", "Professorsslingan 53", 2, 0, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Professorsslingan 57-65", "Professorsslingan 57", 2, 0, LaundryRoom.Quota(4, LaundryRoom.Period.Month)),
        LaundryRoom("Roslagstullsbacken 5", "Roslagstullsbacken 5", 2, 60, null),
        LaundryRoom("Röntgenvägen 1", "Röntgenvägen 1", 2, 60, null),
        LaundryRoom("Simrishamnsvägen 15", "Simrishamnsvägen 15", 1, 0, null),
        LaundryRoom("Skomakargatan 24 A+B", "Skomakargatan 24 A", 2, 60, null),
        LaundryRoom("Studentbacken 21", "Studentbacken 21", 1, 60, null),
        LaundryRoom("Studentbacken 23", "Studentbacken 23", 1, 60, null),
        LaundryRoom("Studentbacken 25-27", "Studentbacken 25", 1, 60, null),
        LaundryRoom("Understensvägen 10", "Understensvägen 10", 1, 0, null),
        LaundryRoom("Understensvägen 20", "Understensvägen 20", 1, 0, null),
        LaundryRoom("Värtavägen 66", "Värtavägen 66", 1, 60, null),
        LaundryRoom("Öregrundsgatan 9-11", "Öregrundsgatan 9", 1, 90, null),
    )
}
