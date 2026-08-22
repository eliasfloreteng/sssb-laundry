//
//  APIClient.swift
//  SSSBLaundry
//

import Foundation

struct APIClient {
    let baseURL: URL
    let session: URLSession
    var objectIdProvider: () -> String?

    init(
        baseURL: URL = Config.baseURL,
        session: URLSession = .shared,
        objectIdProvider: @escaping () -> String?
    ) {
        self.baseURL = baseURL
        self.session = session
        self.objectIdProvider = objectIdProvider
    }

    func getWeek(date: String) async throws -> WeekResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("timeslots"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "date", value: date)]
        let request = try makeRequest(url: components.url!, method: "GET")
        return try await send(request)
    }

    func book(timeslotId: String, groupIds: [Int]) async throws -> ActionResponse {
        try await action(path: "book", timeslotId: timeslotId, groupIds: groupIds)
    }

    func cancel(timeslotId: String, groupIds: [Int]) async throws -> ActionResponse {
        try await action(path: "cancel", timeslotId: timeslotId, groupIds: groupIds)
    }

    private func action(path: String, timeslotId: String, groupIds: [Int]) async throws -> ActionResponse {
        let url = baseURL
            .appendingPathComponent("timeslots")
            .appendingPathComponent(timeslotId)
            .appendingPathComponent(path)
        var request = try makeRequest(url: url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["groupIds": groupIds])
        return try await send(request)
    }

    private func makeRequest(url: URL, method: String) throws -> URLRequest {
        guard let id = objectIdProvider(), !id.isEmpty else {
            throw APIError.local(code: "MISSING_OBJECT_ID", message: "Object id is required.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(id, forHTTPHeaderField: "X-Object-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            // Cancellation is view teardown, not a failure — let it through untouched
            // so `LaundryStore.isCancellation` can still recognise it.
            if urlError.code == .cancelled { throw urlError }
            throw Self.networkError(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.local(code: "BAD_RESPONSE", message: "Invalid response.")
        }
        let decoder = JSONDecoder()
        if !(200..<300).contains(http.statusCode) {
            if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data) {
                throw envelope.error
            }
            let code = http.statusCode >= 500 ? "SERVICE_ERROR" : "UNKNOWN_ERROR"
            throw APIError.local(code: code, message: "The laundry service returned an error.")
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.local(code: "BAD_RESPONSE", message: "Could not read the response.")
        }
    }

    private static func networkError(_ error: URLError) -> APIError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return APIError.local(code: "NO_INTERNET", message: "No internet connection.")
        case .timedOut:
            return APIError.local(code: "TIMEOUT", message: "The request timed out.")
        default:
            return APIError.local(code: "NETWORK_ERROR", message: "Could not reach the laundry service.")
        }
    }
}
