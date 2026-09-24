import Foundation
import Testing
@testable import Updates

@Suite("UpdateFeed")
struct UpdateFeedTests {
    /// A real Ed25519 public key's length, 32 bytes, base64-encoded.
    private static let key = Data(repeating: 7, count: 32).base64EncodedString()
    private static let feed = "https://example.com/app/appcast.xml"

    @Test func aReleaseNamesItsFeedAndKey() throws {
        let status = UpdateFeed.status(in: ["SUFeedURL": Self.feed, "SUPublicEDKey": Self.key])
        let url = try #require(URL(string: Self.feed))
        #expect(status == .configured(UpdateFeed(url: url, publicKey: Self.key)))
    }

    @Test(arguments: [nil, "", "  "])
    func aBuildFromSourceHasNoFeed(_ address: String?) {
        // The release script fills the feed in; everywhere else the build setting expands to nothing.
        var info: [String: Any] = ["SUPublicEDKey": Self.key]
        info["SUFeedURL"] = address
        #expect(UpdateFeed.status(in: info) == .notConfigured)
        #expect(UpdateFeed.status(in: nil) == .notConfigured)
    }

    @Test(arguments: ["http://example.com/appcast.xml", "appcast.xml", "https://", "ftp://example.com/appcast.xml"])
    func aFeedMustBeHTTPS(_ address: String) {
        let status = UpdateFeed.status(in: ["SUFeedURL": address, "SUPublicEDKey": Self.key])
        #expect(status == .invalid(reason: "SUFeedURL is not an https address"))
    }

    @Test(arguments: [nil, "", "not base64!", Data(repeating: 7, count: 16).base64EncodedString()])
    func aFeedNeedsTheKeyItsUpdatesAreSignedWith(_ key: String?) {
        // Sparkle refuses to install an update it can't check against the key.
        var info: [String: Any] = ["SUFeedURL": Self.feed]
        info["SUPublicEDKey"] = key
        #expect(UpdateFeed.status(in: info) == .invalid(reason: "SUPublicEDKey is missing or is not a base64 Ed25519 public key"))
    }

    @Test func theAppsOwnKeyIsWellFormed() throws {
        // The key in App/Info.plist, which release builds ship with.
        let plist = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist) as? [String: Any])
        var release = info
        release["SUFeedURL"] = Self.feed
        guard case .configured = UpdateFeed.status(in: release) else {
            Issue.record("App/Info.plist's SUPublicEDKey is not a valid key: \(UpdateFeed.status(in: release))")
            return
        }
        // The feed itself comes from the release script's build setting, never from the plist.
        #expect(info["SUFeedURL"] as? String == "$(LT_UPDATE_FEED_URL)")
    }
}
