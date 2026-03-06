import Foundation
import Observation

@Observable
final class BookingsViewModel {
    var bookings: [Booking] = []
    var isLoading = false
    var isBooking = false
    var errorMessage: String?
    var feedbackMessage: String?

    private let service = AptusService.shared

    func fetchBookings() async {
        isLoading = true
        errorMessage = nil
        do {
            bookings = try await service.fetchBookings()
            await NotificationService.syncReminders(with: bookings)
        } catch let aptusError as AptusError {
            errorMessage = aptusError.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func unbook(_ booking: Booking) async {
        isBooking = true
        do {
            let feedback = try await service.unbook(path: booking.unbookPath)
            feedbackMessage = feedback
            NotificationService.removeReminder(date: booking.date, time: booking.time)
            await fetchBookings()
        } catch {
            errorMessage = error.localizedDescription
        }
        isBooking = false
    }
}
