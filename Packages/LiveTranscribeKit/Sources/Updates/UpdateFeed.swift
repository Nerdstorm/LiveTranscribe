import Foundation

/// Where the app looks for new releases, and the key their downloads must be signed with, from
/// its Info.plist.
///
/// Only a release names a feed: `scripts/release.sh` sets `SUFeedURL` through the
/// `LT_UPDATE_FEED_URL` build setting, and a build from source leaves it empty.
public struct UpdateFeed: Equatable, Sendable {
    /// The Info.plist key of the feed's address (Sparkle's).
    public static let urlKey = "SUFeedURL"
    /// The Info.plist key of the public EdDSA key (Sparkle's).
    public static let publicKeyKey = "SUPublicEDKey"

    /// The appcast's address.
    public let url: URL
    /// The public half of the EdDSA key that signs every update, base64-encoded.
    public let publicKey: String

    /// What an Info.plist says about updates.
    public enum Status: Equatable, Sendable {
        /// No feed: a build from source, which never checks for updates.
        case notConfigured
        /// A feed Sparkle would refuse, and why.
        case invalid(reason: String)
        case configured(UpdateFeed)
    }

    /// What `infoDictionary` (normally `Bundle.main.infoDictionary`) says about updates.
    public static func status(in infoDictionary: [String: Any]?) -> Status {
        let address = (infoDictionary?[urlKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !address.isEmpty else { return .notConfigured }
        guard let url = URL(string: address), url.scheme == "https", url.host?.isEmpty == false else {
            return .invalid(reason: "\(urlKey) is not an https address")
        }
        let publicKey = (infoDictionary?[publicKeyKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An Ed25519 public key is 32 bytes.
        guard let key = Data(base64Encoded: publicKey), key.count == 32 else {
            return .invalid(reason: "\(publicKeyKey) is missing or is not a base64 Ed25519 public key")
        }
        return .configured(UpdateFeed(url: url, publicKey: publicKey))
    }
}
