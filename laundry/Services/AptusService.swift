import Foundation

actor AptusService {
    static let shared = AptusService()

    private let baseURL = "https://sssb.aptustotal.se/AptusPortal"
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: config)
    }

    // MARK: - Authentication

    func login(username: String, password: String) async throws -> Bool {
        // Step 1: GET login page to extract salt and token
        let loginURL = URL(string: "\(baseURL)/Account/Login")!
        let (loginData, _) = try await session.data(from: loginURL)
        let loginHTML = String(data: loginData, encoding: .utf8) ?? ""
        let loginPage = try HTMLParser.parseLoginPage(html: loginHTML)

        // Step 2: Encode password
        let encodedPassword = PasswordEncoder.encode(password: password, salt: loginPage.salt)

        // Step 3: POST login
        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let formFields: [(String, String)] = [
            ("DeviceType", "PC"),
            ("DesktopSelected", "true"),
            ("__RequestVerificationToken", loginPage.verificationToken),
            ("UserName", username),
            ("Password", password),
            ("PwEnc", encodedPassword),
            ("PasswordSalt", loginPage.salt)
        ]

        let body = formFields.map { key, value in
            "\(urlEncode(key))=\(urlEncode(value))"
        }.joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (_, response) = try await session.data(for: request)

        // Step 4: Check for .ASPXAUTH cookie
        if let httpResponse = response as? HTTPURLResponse,
           let cookies = HTTPCookieStorage.shared.cookies(for: loginURL) {
            let hasAuth = cookies.contains { $0.name == ".ASPXAUTH" }
            return hasAuth && (200...399).contains(httpResponse.statusCode)
        }
        return false
    }

    var isAuthenticated: Bool {
        guard let url = URL(string: baseURL) else { return false }
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        return cookies.contains { $0.name == ".ASPXAUTH" }
    }

    func logout() {
        guard let url = URL(string: baseURL) else { return }
        HTTPCookieStorage.shared.cookies(for: url)?.forEach {
            HTTPCookieStorage.shared.deleteCookie($0)
        }
    }

    // MARK: - Bookings

    func fetchBookings() async throws -> [Booking] {
        let html = try await fetchHTML(path: "/CustomerBooking")
        return try HTMLParser.parseBookings(html: html)
    }

    func unbook(path: String) async throws -> String? {
        let html = try await fetchHTML(path: path)
        return HTMLParser.parseFeedback(html: html)
    }

    // MARK: - First Available

    func fetchFirstAvailable(categoryId: Int = 35, count: Int = 10) async throws -> [TimeSlot] {
        let html = try await fetchHTML(path: "/CustomerBooking/FirstAvailable?categoryId=\(categoryId)&firstX=\(count)")
        return try HTMLParser.parseFirstAvailable(html: html)
    }

    func bookFirstAvailable(passNo: Int, passDate: String, bookingGroupId: Int) async throws -> String? {
        let path = "/CustomerBooking/BookFirstAvailable?passNo=\(passNo)&passDate=\(passDate)&bookingGroupId=\(bookingGroupId)"
        let html = try await fetchHTML(path: path)
        return HTMLParser.parseFeedback(html: html)
    }

    // MARK: - Calendar

    func fetchLocationGroups(categoryId: Int = 35) async throws -> [LaundryGroup] {
        let html = try await fetchAJAX(path: "/CustomerBooking/CustomerLocationGroups?categoryId=\(categoryId)")
        return try HTMLParser.parseLocationGroups(html: html)
    }

    func fetchWeekCalendar(groupId: Int, passDate: String? = nil) async throws -> WeekCalendar {
        var path = "/CustomerBooking/BookingCalendar?bookingGroupId=\(groupId)"
        if let date = passDate {
            path += "&passDate=\(date)"
        }
        let html = try await fetchHTML(path: path)
        return try HTMLParser.parseWeekCalendar(html: html, groupId: groupId)
    }

    func bookFromCalendar(passNo: Int, passDate: String, bookingGroupId: Int) async throws -> String? {
        let path = "/CustomerBooking/Book?passNo=\(passNo)&passDate=\(passDate)&bookingGroupId=\(bookingGroupId)"
        let html = try await fetchHTML(path: path)
        return HTMLParser.parseFeedback(html: html)
    }

    func unbookFromCalendar(path: String) async throws -> String? {
        let html = try await fetchHTML(path: path)
        return HTMLParser.parseFeedback(html: html)
    }

    // MARK: - Helpers

    private func fetchHTML(path: String) async throws -> String {
        let cleanPath = path.hasPrefix("/AptusPortal") ? path : "/AptusPortal\(path.hasPrefix("/") ? "" : "/")\(path)"
        let url = URL(string: "https://sssb.aptustotal.se\(cleanPath)")!
        let (data, response) = try await session.data(from: url)

        // Check for session expiry (redirect to login)
        if let httpResponse = response as? HTTPURLResponse,
           let finalURL = httpResponse.url ?? response.url,
           finalURL.path.contains("Account/Login") {
            throw AptusError.sessionExpired
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    private func fetchAJAX(path: String) async throws -> String {
        let cleanPath = path.hasPrefix("/AptusPortal") ? path : "/AptusPortal\(path.hasPrefix("/") ? "" : "/")\(path)"
        let url = URL(string: "https://sssb.aptustotal.se\(cleanPath)")!
        var request = URLRequest(url: url)
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let (data, response) = try await session.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           let finalURL = httpResponse.url ?? response.url,
           finalURL.path.contains("Account/Login") {
            throw AptusError.sessionExpired
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    private func urlEncode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: "=", with: "%3D") ?? string
    }
}

enum AptusError: LocalizedError {
    case sessionExpired
    case loginFailed
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .sessionExpired: return "Session expired. Please log in again."
        case .loginFailed: return "Login failed. Check your credentials."
        case .networkError(let msg): return msg
        }
    }
}
