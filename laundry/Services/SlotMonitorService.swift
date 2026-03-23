import BackgroundTasks
import Foundation

enum SlotMonitorService {
    static let taskIdentifier = "se.sssb.laundry.slotcheck"

    // MARK: - Registration

    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleBackgroundTask(refreshTask)
        }
    }

    // MARK: - Scheduling

    static func scheduleNextCheck(for calendar: WeekCalendar, groupName: String?) {
        let settings = SlotMonitorSettings.load()
        guard settings.isEnabled else { return }

        let now = Date()
        let cal = Calendar.current

        // Collect unavailable slots from today that haven't passed startTime + 17min
        var candidates: [Date] = []
        for day in calendar.days {
            for slot in day.slots where slot.status == .unavailable {
                guard let slotDate = slot.date,
                      cal.isDateInToday(slotDate) else { continue }
                guard let startTime = parseStartTime(from: slot.time, on: slotDate) else { continue }
                let checkTime = startTime.addingTimeInterval(17 * 60)
                if checkTime > now {
                    candidates.append(checkTime)
                }
            }
        }

        guard let earliest = candidates.min() else { return }

        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = earliest

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Best-effort scheduling; iOS may deny for various reasons
        }
    }

    // MARK: - Background Task Handler

    static func handleBackgroundTask(_ task: BGAppRefreshTask) {
        let settings = SlotMonitorSettings.load()
        guard settings.isEnabled else {
            task.setTaskCompleted(success: true)
            return
        }

        let workTask = Task {
            // Check if at home
            guard await LocationService.isAtHome() else {
                task.setTaskCompleted(success: true)
                return
            }

            // Fetch currently available slots
            do {
                let available = try await AptusService.shared.fetchFirstAvailable()
                let now = Date()
                let cal = Calendar.current

                for slot in available {
                    guard let slotDate = slot.date, cal.isDateInToday(slotDate) else { continue }
                    guard let startTime = parseStartTime(from: slot.time, on: slotDate) else { continue }

                    // Slot was likely freed by the 15-min rule if we're past startTime + 15min
                    let freedThreshold = startTime.addingTimeInterval(15 * 60)
                    let slotEnd = startTime.addingTimeInterval(2 * 60 * 60)

                    if now >= freedThreshold && now <= slotEnd {
                        await NotificationService.sendFreedSlotNotification(
                            time: slot.time,
                            groupName: slot.groupName
                        )
                    }
                }

                // Reschedule for next candidate by fetching calendar for each group
                // Best effort: schedule a new check for roughly 30min from now as fallback
                let fallback = BGAppRefreshTaskRequest(identifier: taskIdentifier)
                fallback.earliestBeginDate = now.addingTimeInterval(30 * 60)
                try? BGTaskScheduler.shared.submit(fallback)

            } catch {
                // Network failure — try again later
                let retry = BGAppRefreshTaskRequest(identifier: taskIdentifier)
                retry.earliestBeginDate = Date().addingTimeInterval(15 * 60)
                try? BGTaskScheduler.shared.submit(retry)
            }

            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            workTask.cancel()
        }
    }

    // MARK: - Helpers

    /// Parse "07:00 - 09:00" style time string, returning the start time Date for a given day
    static func parseStartTime(from time: String, on date: Date) -> Date? {
        let timeStr = time.prefix(while: { $0 != " " && $0 != "-" }).trimmingCharacters(in: .whitespaces)
        let parts = timeStr.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else { return nil }

        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)
    }
}
