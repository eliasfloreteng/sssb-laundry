//
//  InviteLink.swift
//  SSSBLaundry
//

import Foundation
import UIKit

/// The one link the app hands out, and everything that reads one back.
///
/// An invite is a universal link on the API's own host. With the app installed,
/// iOS opens it here and the object number is applied without anything being
/// typed. Without the app, Safari shows `api/site/invite.html`, which puts this
/// same link on the clipboard before handing the visitor to TestFlight — that
/// copy is the deferred half of the deep link, and `objectId(fromPasted:)` is
/// what picks it up on the sign-in screen once the app finally exists.
///
/// The object number rides in the *fragment*, never the query: a fragment is
/// never sent to any server, and an object number is a credential that has no
/// business in an access log.
nonisolated enum InviteLink {
    /// Claimed by `applinks:` in the entitlement and by the API's
    /// `apple-app-site-association`. Changing it means changing both.
    static let path = "/invite"

    /// The link to share. Without an object number it is simply the landing
    /// page: there is nothing to deep link to, and the recipient signs in with a
    /// number of their own.
    static func url(objectId: String?) -> URL {
        let trimmed = objectId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty,
              var components = URLComponents(url: Config.baseURL, resolvingAgainstBaseURL: false)
        else { return Config.baseURL }
        components.path = path
        components.fragment = trimmed
        return components.url ?? Config.baseURL
    }

    /// The object number an incoming universal link carries, if it is ours and
    /// carries one at all.
    static func objectId(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == Config.baseURL.host(),
              components.path == path,
              let fragment = components.fragment
        else { return nil }
        return objectId(fromPasted: fragment)
    }

    /// Reads an object number out of whatever was on the clipboard — an invite
    /// link, or the bare number the invite page also offers to copy. Anything
    /// that is not digits or a hyphen separates one candidate from the next, so
    /// the hyphen in the host name never confuses the number in the fragment.
    static func objectId(fromPasted text: String) -> String? {
        text
            .split(whereSeparator: { !isDigit($0) && $0 != "-" })
            .first(where: isObjectNumber)
            .map(String.init)
    }

    /// Aptus's own shape, `1234-5678-901`. Strict on purpose: this is what tells
    /// an invite on the clipboard from whatever else happens to be there.
    private static func isObjectNumber(_ candidate: Substring) -> Bool {
        let parts = candidate.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [4, 4, 3] else { return false }
        return parts.allSatisfy { $0.allSatisfy(isDigit) }
    }

    private static func isDigit(_ character: Character) -> Bool {
        ("0"..."9").contains(character)
    }
}

extension InviteLink {
    /// Whether the clipboard plausibly holds an invite, asked the only way iOS
    /// allows without a paste prompt: patterns, never contents. The paste itself
    /// goes through `PasteButton`, where the tap *is* the permission — so a false
    /// positive here costs an offer the user ignores, and never a leaked
    /// clipboard.
    @MainActor
    static func clipboardMayHoldInvite() async -> Bool {
        let patterns: Set<PartialKeyPath<UIPasteboard.DetectedValues>> = [\.probableWebURL, \.number]
        let found = try? await UIPasteboard.general.detectedPatterns(for: patterns)
        return found?.isEmpty == false
    }
}

enum InviteSetting {
    static let includeObjectIdKey = "invite.includeObjectId"

    /// On by default: the invite exists so an apartment shares one object number,
    /// and a link that leaves it out is the rarer "just look at the app" case.
    static let defaultIncludeObjectId = true
}
