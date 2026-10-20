//
//  FeedbackSheet.swift
//  SSSBLaundry
//

import SwiftUI
import UIKit

/// Feedback straight to the developer: the keyboard is up the moment the sheet
/// is, and the object number, version, device and laundry room go along
/// without being asked for. The draft outlives the sheet, so a swipe down or a failed send costs
/// nothing typed.
struct FeedbackSheet: View {
    @AppStorage(FeedbackSetting.draftKey) private var draft: String = ""
    @AppStorage(LaundryRooms.selectedIdKey) private var laundryRoomId: String = ""
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool
    @State private var sending = false
    @State private var sent = false
    @State private var error: APIError?

    private var message: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Group {
                if sent {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                            .symbolEffect(.bounce, value: sent)
                        Text("Thanks — it’s sent.")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Form {
                        TextField("What’s on your mind?", text: $draft, axis: .vertical)
                            .lineLimit(6...)
                            .focused($editorFocused)
                            .disabled(sending)
                    }
                }
            }
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else if !sent {
                        Button("Send") { send() }
                            .disabled(message.isEmpty)
                    }
                }
            }
            .alert(
                error.map { ErrorPresenter.headline(for: $0) } ?? ErrorPresenter.genericHeadline,
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
                presenting: error
            ) { _ in
                Button("OK", role: .cancel) { error = nil }
            } message: { error in
                Text(ErrorPresenter.explanation(for: error))
            }
        }
        .sensoryFeedback(.success, trigger: sent)
        .presentationDetents([.medium, .large])
        .onAppear { editorFocused = true }
    }

    private func send() {
        sending = true
        Task {
            do {
                let client = APIClient(objectIdProvider: { ObjectIdStore.get() })
                try await client.sendFeedback(message: message, context: FeedbackSetting.context(laundryRoomId: laundryRoomId))
                draft = ""
                editorFocused = false
                sent = true
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            } catch let apiError as APIError {
                error = apiError
            } catch {
                self.error = .local(code: "FEEDBACK_FAILED", message: error.localizedDescription)
            }
            sending = false
        }
    }
}

enum FeedbackSetting {
    static let draftKey = "feedback.draft"

    /// What helps read a message without asking the resident anything. The
    /// object number itself travels as the `X-Object-Id` header.
    static func context(laundryRoomId: String) -> [String: String] {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var context = [
            "appVersion": "\(version) (\(build))",
            "osVersion": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "device": hardwareModel,
            "locale": Locale.current.identifier
        ]
        if let room = LaundryRooms.room(id: laundryRoomId) {
            context["laundryRoom"] = room.address
        }
        return context
    }

    /// `iPhone17,1` rather than `UIDevice.model`'s bare "iPhone".
    private static var hardwareModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

#Preview {
    FeedbackSheet()
}
