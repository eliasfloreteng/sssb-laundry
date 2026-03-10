import Foundation
import SwiftSoup

enum HTMLParser {

    // MARK: - Login Page

    struct LoginPageData {
        let salt: String
        let verificationToken: String
    }

    static func parseLoginPage(html: String) throws -> LoginPageData {
        let doc = try SwiftSoup.parse(html)
        let salt = try doc.select("input#PasswordSalt").attr("value")
        let token = try doc.select("input[name=__RequestVerificationToken]").attr("value")
        return LoginPageData(salt: salt, verificationToken: token)
    }

    // MARK: - My Bookings

    static func parseBookings(html: String) throws -> [Booking] {
        let doc = try SwiftSoup.parse(html)
        var bookings: [Booking] = []

        let cards = try doc.select(".bookingCard")
        for card in cards {
            // Skip the "new booking" card and disabled (history) cards
            guard try card.select("#newBookingCard").isEmpty(),
                  try card.attr("data-disabled").isEmpty else {
                continue
            }

            guard let unbookButton = try card.select("button.unbookButton").first() else {
                continue
            }

            let bookingId = try unbookButton.attr("id")

            // Extract unbook path from ConfirmCancelBooking script
            let scripts = try card.select("script")
            var unbookPath = "/AptusPortal/CustomerBooking/Unbook/\(bookingId)"
            for script in scripts {
                let scriptText = try script.html()
                if let range = scriptText.range(of: "ConfirmCancelBooking\\('[^']*',\\s*'([^']*)'", options: .regularExpression) {
                    let match = scriptText[range]
                    if let pathRange = match.range(of: "',\\s*'([^']*)'", options: .regularExpression) {
                        var path = String(match[pathRange])
                        path = path.replacingOccurrences(of: "', '", with: "")
                        path = path.replacingOccurrences(of: "'", with: "")
                        unbookPath = path.trimmingCharacters(in: .whitespaces)
                    }
                }
            }

            let divs = try card.select(":root > div")
            let time = divs.count > 0 ? try divs.get(0).text() : ""
            let date = divs.count > 1 ? try divs.get(1).text() : ""

            // Find group name - look for div containing "Grupp"
            var group = ""
            for div in divs {
                let text = try div.text()
                if text.contains("Grupp") {
                    group = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }

            let parsedDate = DateFormatting.parseSwedishBookingDate(date)

            bookings.append(Booking(
                id: bookingId,
                time: time,
                date: parsedDate,
                group: group,
                unbookPath: unbookPath
            ))
        }
        return bookings
    }

    // MARK: - First Available

    static func parseFirstAvailable(html: String) throws -> [TimeSlot] {
        let doc = try SwiftSoup.parse(html)
        var slots: [TimeSlot] = []

        let cards = try doc.select(".bookingCard")
        for card in cards {
            guard let button = try card.select("button.bookButton").first() else {
                continue
            }

            let onclick = try button.attr("onclick")
            guard let bookPath = extractPath(from: onclick) else { continue }

            let params = parseQueryParams(from: bookPath)
            let passNo = Int(params["passNo"] ?? "") ?? 0
            let passDate = params["passDate"] ?? ""
            let groupId = Int(params["bookingGroupId"] ?? "") ?? 0

            let divs = try card.select(":root > div")
            let time = divs.count > 0 ? try divs.get(0).text() : ""

            var groupName: String?
            for div in divs {
                let text = try div.text()
                if text.contains("Grupp") {
                    groupName = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }

            let parsedDate = DateFormatting.parseISO(passDate)

            slots.append(TimeSlot(
                passNo: passNo,
                passDate: passDate,
                date: parsedDate,
                groupId: groupId,
                time: time,
                status: .available,
                bookPath: bookPath,
                unbookPath: nil,
                groupName: groupName
            ))
        }
        return slots
    }

    // MARK: - Week Calendar

    static func parseWeekCalendar(html: String, groupId: Int) throws -> WeekCalendar {
        let doc = try SwiftSoup.parse(html)
        var days: [DayColumn] = []

        let dayColumns = try doc.select(".dayColumn")
        for column in dayColumns {
            let dayName = try column.select(".weekDay").text()
            let dayOfMonth = try column.select(".dayOfMonth").text()

            var columnSlots: [TimeSlot] = []  // mutated later for date reconstruction
            let intervals = try column.select(".interval")

            for interval in intervals {
                let classes = try interval.className()
                let timeDiv = try interval.select(":root > div").first()
                let timeText = try timeDiv?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let status: TimeSlot.Status
                var bookPath: String?
                var unbookPath: String?
                var passNo = 0
                var passDate = ""

                if classes.contains("bookable") {
                    status = .available
                    if let btn = try interval.select("button.bookButton").first() {
                        let onclick = try btn.attr("onclick")
                        bookPath = extractPath(from: onclick)
                        if let bp = bookPath {
                            let params = parseQueryParams(from: bp)
                            passNo = Int(params["passNo"] ?? "") ?? 0
                            passDate = params["passDate"] ?? ""
                        }
                    }
                } else if classes.contains("own") {
                    status = .own
                    let scripts = try interval.select("script")
                    for script in scripts {
                        let scriptText = try script.html()
                        if let path = extractUnbookPath(from: scriptText) {
                            unbookPath = path
                            let params = parseQueryParams(from: path)
                            passDate = params["passDate"] ?? ""
                        }
                    }
                } else {
                    status = .unavailable
                }

                let parsedDate = DateFormatting.parseISO(passDate)

                columnSlots.append(TimeSlot(
                    passNo: passNo,
                    passDate: passDate,
                    date: parsedDate,
                    groupId: groupId,
                    time: timeText,
                    status: status,
                    bookPath: bookPath,
                    unbookPath: unbookPath,
                    groupName: nil
                ))
            }

            // Reconstruct dates for unavailable slots: use passDate from a sibling slot
            let siblingPassDate = columnSlots.first(where: { !$0.passDate.isEmpty })?.passDate ?? ""
            if !siblingPassDate.isEmpty {
                columnSlots = columnSlots.map { slot in
                    if slot.passDate.isEmpty {
                        let parsedDate = DateFormatting.parseISO(siblingPassDate)
                        return TimeSlot(
                            passNo: slot.passNo,
                            passDate: siblingPassDate,
                            date: parsedDate,
                            groupId: slot.groupId,
                            time: slot.time,
                            status: slot.status,
                            bookPath: slot.bookPath,
                            unbookPath: slot.unbookPath,
                            groupName: slot.groupName
                        )
                    }
                    return slot
                }
            }

            days.append(DayColumn(
                dayName: dayName,
                dayOfMonth: dayOfMonth,
                slots: columnSlots
            ))
        }

        // If any day still has no dates, try to reconstruct from navigation links
        // The prev/next week links contain passDate params defining the week range

        // Parse week navigation
        var prevPath: String?
        var nextPath: String?
        var weekLabel: String?

        let navLinks = try doc.select("footer a")
        for link in navLinks {
            let ariaLabel = try link.attr("aria-label")
            let href = try link.attr("href")
            if ariaLabel.contains("regående") || ariaLabel.contains("Föregående") {
                prevPath = href
            } else if ariaLabel.contains("Nästa") || ariaLabel.contains("ästa") {
                nextPath = href
            }
        }

        // Extract week label like "Vecka 10"
        let footerTds = try doc.select("footer td")
        for td in footerTds {
            let text = try td.text()
            if text.contains("Vecka") {
                weekLabel = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\u{00a0}", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                break
            }
        }

        return WeekCalendar(
            days: days,
            previousWeekPath: prevPath,
            nextWeekPath: nextPath,
            weekLabel: weekLabel
        )
    }

    // MARK: - Location Groups

    static func parseLocationGroups(html: String) throws -> [LaundryGroup] {
        let doc = try SwiftSoup.parse(html)
        var groups: [LaundryGroup] = []

        let buttons = try doc.select("button.bookingNavigation")
        for button in buttons {
            let onclick = try button.attr("onclick")
            // Skip "First available" button
            guard onclick.contains("BookingCalendarOverview") else { continue }

            guard let range = onclick.range(of: "bookingGroupId=(\\d+)", options: .regularExpression) else {
                continue
            }
            let match = String(onclick[range])
            let idStr = match.replacingOccurrences(of: "bookingGroupId=", with: "")
            guard let id = Int(idStr) else { continue }

            let name = try button.attr("aria-label")
            groups.append(LaundryGroup(id: id, name: name))
        }
        return groups
    }

    // MARK: - Feedback

    static func parseFeedback(html: String) -> String? {
        guard let range = html.range(of: "FeedbackDialog\\('([^']*)'", options: .regularExpression) else {
            return nil
        }
        var message = String(html[range])
        message = message.replacingOccurrences(of: "FeedbackDialog('", with: "")
        message = message.replacingOccurrences(of: "'", with: "")
        // Clean HTML entities
        message = message.replacingOccurrences(of: "<b>", with: "")
        message = message.replacingOccurrences(of: "</b>", with: "")
        message = message.replacingOccurrences(of: "&nbsp;", with: " ")
        message = message.replacingOccurrences(of: "<br>", with: "\n")
        message = message.replacingOccurrences(of: "<br/>", with: "\n")
        message = message.replacingOccurrences(of: "<br />", with: "\n")
        return message.isEmpty ? nil : message
    }

    // MARK: - Helpers

    private static func extractPath(from onclick: String) -> String? {
        // Extract URL from DoBooking('...') pattern
        guard let startRange = onclick.range(of: "('") else { return nil }
        let afterStart = onclick[startRange.upperBound...]
        guard let endRange = afterStart.range(of: "')") else { return nil }
        var path = String(afterStart[afterStart.startIndex..<endRange.lowerBound])
        path = path.replacingOccurrences(of: "&amp;", with: "&")
        return path
    }

    private static func extractUnbookPath(from script: String) -> String? {
        // Extract second argument from ConfirmCancelBooking('id', '/path/...', ...)
        let parts = script.components(separatedBy: "'")
        // Parts: [before, id, comma-space, path, comma-space, message, ...]
        guard parts.count >= 4 else { return nil }
        let path = parts[3]
        guard path.contains("Unbook") else { return nil }
        return path.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func parseQueryParams(from path: String) -> [String: String] {
        var params: [String: String] = [:]
        guard let queryStart = path.range(of: "?") else { return params }
        let query = String(path[queryStart.upperBound...])
        for pair in query.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2 {
                params[parts[0]] = parts[1]
            }
        }
        return params
    }
}
