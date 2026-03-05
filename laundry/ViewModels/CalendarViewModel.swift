import Foundation
import Observation

@Observable
final class CalendarViewModel {
    var firstAvailableSlots: [TimeSlot] = []
    var weekCalendar: WeekCalendar?
    var groups: [LaundryGroup] = []
    var selectedGroup: LaundryGroup?
    var isLoading = false
    var errorMessage: String?
    var feedbackMessage: String?

    private let service = AptusService.shared

    // MARK: - First Available

    func fetchFirstAvailable() async {
        isLoading = true
        errorMessage = nil
        do {
            firstAvailableSlots = try await service.fetchFirstAvailable()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func bookFirstAvailable(_ slot: TimeSlot) async {
        do {
            let feedback = try await service.bookFirstAvailable(
                passNo: slot.passNo,
                passDate: slot.date,
                bookingGroupId: slot.groupId
            )
            feedbackMessage = feedback
            await fetchFirstAvailable()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Groups

    func fetchGroups() async {
        do {
            groups = try await service.fetchLocationGroups()
            if selectedGroup == nil, let first = groups.first {
                selectedGroup = first
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Week Calendar

    func fetchWeekCalendar(passDate: String? = nil) async {
        guard let group = selectedGroup else { return }
        isLoading = true
        errorMessage = nil
        do {
            weekCalendar = try await service.fetchWeekCalendar(groupId: group.id, passDate: passDate)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func bookFromCalendar(_ slot: TimeSlot) async {
        do {
            let feedback = try await service.bookFromCalendar(
                passNo: slot.passNo,
                passDate: slot.date,
                bookingGroupId: slot.groupId
            )
            feedbackMessage = feedback
            // Refresh same week
            await fetchWeekCalendar(passDate: slot.date)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unbookFromCalendar(_ slot: TimeSlot) async {
        guard let path = slot.unbookPath else { return }
        do {
            let feedback = try await service.unbookFromCalendar(path: path)
            feedbackMessage = feedback
            await fetchWeekCalendar(passDate: slot.date)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func navigatePreviousWeek() async {
        guard let path = weekCalendar?.previousWeekPath else { return }
        let passDate = extractPassDate(from: path)
        await fetchWeekCalendar(passDate: passDate)
    }

    func navigateNextWeek() async {
        guard let path = weekCalendar?.nextWeekPath else { return }
        let passDate = extractPassDate(from: path)
        await fetchWeekCalendar(passDate: passDate)
    }

    func selectGroup(_ group: LaundryGroup) async {
        selectedGroup = group
        await fetchWeekCalendar()
    }

    private func extractPassDate(from path: String) -> String? {
        guard let range = path.range(of: "passDate=([^&]+)", options: .regularExpression) else {
            return nil
        }
        return String(path[range]).replacingOccurrences(of: "passDate=", with: "")
    }
}
