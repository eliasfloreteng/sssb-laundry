//
//  APIClient.swift
//  sssb-laundry
//

import Foundation

final class APIClient: @unchecked Sendable {
    static let shared = APIClient()

    static let defaultBaseURL = "https://sssb-laundry-api.eliasfloreteng.workers.dev"

    private var baseURL: URL {
        let stored = UserDefaults.standard.string(forKey: "apiBaseURL") ?? ""
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: APIClient.defaultBaseURL)!
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: s) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(s)")
        }
        return d
    }()

    private let encoder = JSONEncoder()

    private func request(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        objectId: String
    ) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(objectId, forHTTPHeaderField: "X-Object-Id")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if !(200..<300).contains(http.statusCode) {
            if let apiErr = try? decoder.decode(APIError.self, from: data) {
                throw apiErr
            }
            throw URLError(.init(rawValue: http.statusCode))
        }
        #if DEBUG
        if let s = String(data: data, encoding: .utf8) {
            print("[API] \(method) \(path) →", s.prefix(600))
        }
        #endif
        return data
    }

    func me(objectId: String) async throws -> MeResponse {
        let data = try await request(path: "/me", objectId: objectId)
        return try decoder.decode(MeResponse.self, from: data)
    }

    func slots(objectId: String, includeAll: Bool = false, cursor: String? = nil, limit: Int = 50) async throws -> SlotsPage {
        var q: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if includeAll { q.append(URLQueryItem(name: "include", value: "all")) }
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        let data = try await request(path: "/slots", query: q, objectId: objectId)
        if let page = try? decoder.decode(SlotsPage.self, from: data) {
            return page
        }
        let items = try decoder.decode([Slot].self, from: data)
        return SlotsPage(items: items, nextCursor: nil)
    }

    func book(objectId: String, date: String, passNo: Int, prefer: BookingPreference = .both) async throws {
        let body = try encoder.encode(["prefer": prefer.rawValue])
        _ = try await request(
            path: "/slots/\(date)/\(passNo)/book",
            method: "POST",
            body: body,
            objectId: objectId
        )
    }

    func bookings(objectId: String) async throws -> [Booking] {
        let data = try await request(path: "/bookings", objectId: objectId)
        if let page = try? decoder.decode(BookingsPage.self, from: data) {
            return page.items
        }
        return try decoder.decode([Booking].self, from: data)
    }

    func bookingsHistory(objectId: String, cursor: String? = nil, limit: Int = 50) async throws -> BookingsPage {
        var q: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        let data = try await request(path: "/bookings/history", query: q, objectId: objectId)
        if let page = try? decoder.decode(BookingsPage.self, from: data) {
            return page
        }
        let items = try decoder.decode([Booking].self, from: data)
        return BookingsPage(items: items, nextCursor: nil)
    }

    func cancelBooking(objectId: String, bookingId: String) async throws {
        _ = try await request(path: "/bookings/\(bookingId)", method: "DELETE", objectId: objectId)
    }

    func cancelSlotBookings(objectId: String, date: String, passNo: Int) async throws {
        _ = try await request(path: "/slots/\(date)/\(passNo)/bookings", method: "DELETE", objectId: objectId)
    }
}
