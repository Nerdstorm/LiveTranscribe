@testable import About
import Foundation
import Shared
import Testing

@Suite("Acknowledgements")
struct AcknowledgementsTests {
    /// Package.resolved's pins as the acknowledgements name them.
    private struct Pin: Hashable {
        let name: String
        let version: String
    }

    private static func resolvedPins() throws -> Set<Pin> {
        struct Resolved: Decodable {
            struct Entry: Decodable {
                struct State: Decodable {
                    let version: String?
                    let revision: String
                }

                let location: String
                let state: State
            }

            let pins: [Entry]
        }
        let file = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Package.resolved")
        let resolved = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: file))
        return Set(resolved.pins.map { entry in
            var name = URL(string: entry.location)?.lastPathComponent ?? entry.location
            if name.hasSuffix(".git") { name.removeLast(4) }
            return Pin(name: name, version: entry.state.version ?? String(entry.state.revision.prefix(7)))
        })
    }

    @Test func everyResolvedPackageIsAcknowledgedAtItsVersion() throws {
        let acknowledged = Set(try Acknowledgements.bundled().packages.map { Pin(name: $0.name, version: $0.version) })
        let resolved = try Self.resolvedPins()
        #expect(
            acknowledged == resolved,
            "Acknowledgements.json is out of date: run scripts/generate-acknowledgements.sh and commit it"
        )
    }

    @Test func everyPackageCarriesItsLicence() throws {
        for package in try Acknowledgements.bundled().packages {
            #expect(!package.notices.isEmpty, "\(package.name)")
            #expect(package.notices.allSatisfy { !$0.text.isEmpty }, "\(package.name)")
            #expect(package.url.hasPrefix("https://"), "\(package.name)")
        }
    }

    @Test func mlxCarriesTheNoticeOfTheFFTItBundles() throws {
        // PocketFFT's BSD licence is in its header, not a file of its own.
        let mlx = try #require(try Acknowledgements.bundled().packages.first { $0.name == "mlx-swift" })
        let fft = try #require(mlx.notices.first { $0.file.hasSuffix("pocketfft.h") })
        #expect(fft.text.contains("Redistributions in binary form must reproduce the above copyright notice"))
    }

    @Test func everyDefaultModelIsCredited() {
        let defaults = AppSettings.defaults
        let credited = Set(ModelCredit.defaults.map(\.repository))
        for model in [defaults.sttModel, defaults.llmModel, defaults.vadModel] {
            #expect(credited.contains(model), "\(model) has no ModelCredit")
        }
    }

    @Test func theCreditsNameEveryModelAndPackageWithItsLicence() throws {
        let acknowledgements = try Acknowledgements.bundled()
        let credits = AboutCredits.text(acknowledgements: acknowledgements, models: ModelCredit.defaults).string
        for model in ModelCredit.defaults {
            #expect(credits.contains(model.original))
            #expect(credits.contains(model.licence))
        }
        for package in acknowledgements.packages {
            #expect(credits.contains("\(package.name) \(package.version)"))
            for notice in package.notices {
                #expect(credits.contains(notice.text), "\(package.name) \(notice.file)")
            }
        }
    }

    @Test func missingNoticesAreSaidRatherThanLeftOut() {
        let credits = AboutCredits.text(acknowledgements: nil, models: ModelCredit.defaults).string
        #expect(credits.contains("The licence notices are missing from this copy of the app."))
    }
}
