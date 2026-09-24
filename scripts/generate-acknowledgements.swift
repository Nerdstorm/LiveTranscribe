// Collects the licence notices of every Swift package in Package.resolved into the JSON the
// About panel shows. Run through generate-acknowledgements.sh, which resolves the packages first.
//
// Usage: generate-acknowledgements.swift <Package.resolved> <checkouts directory> <output.json>

import Foundation

struct Resolved: Decodable {
    struct Pin: Decodable {
        struct State: Decodable {
            let version: String?
            let revision: String
        }

        let identity: String
        let location: String
        let state: State
    }

    let pins: [Pin]
}

struct Acknowledgements: Encodable {
    struct Package: Encodable {
        let name: String
        let version: String
        let url: String
        let notices: [Notice]
    }

    struct Notice: Encodable {
        let file: String
        let text: String
    }

    let packages: [Package]
}

/// Licence text written into a source file's header rather than into a file of its own.
let embeddedNotices = [
    // MLX's FFT, which the README's Models and credits section mentions.
    "mlx-swift": ["Source/Cmlx/mlx/mlx/3rdparty/pocketfft.h"],
]

/// Names of files that hold a licence or notice.
let noticePrefixes = ["LICENSE", "LICENCE", "COPYING", "NOTICE"]
/// Extensions a notice file may have; anything else (source code, say) is not one.
let noticeExtensions: Set<String> = ["", "txt", "md", "mit"]
/// Folders whose files are not part of what gets built.
let skippedFolders: Set<String> = [".git", ".github", "test", "tests", "example", "examples", "doc", "docs", "benchmarks"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-acknowledgements: \(message)\n".utf8))
    exit(1)
}

/// The repository's name, from its location: "https://github.com/ml-explore/mlx-swift.git" is mlx-swift.
func repositoryName(_ location: String) -> String {
    let last = URL(string: location)?.lastPathComponent ?? location
    return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
}

func noticeFiles(in checkout: URL) -> [String] {
    guard let walker = FileManager.default.enumerator(at: checkout, includingPropertiesForKeys: [.isDirectoryKey]) else {
        fail("can't read \(checkout.path)")
    }
    var found: [String] = []
    for case let file as URL in walker {
        let name = file.lastPathComponent
        if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if skippedFolders.contains(name.lowercased()) { walker.skipDescendants() }
            continue
        }
        let upper = name.uppercased()
        guard noticePrefixes.contains(where: upper.hasPrefix),
              noticeExtensions.contains(file.pathExtension.lowercased())
        else { continue }
        found.append(String(file.path.dropFirst(checkout.path.count + 1)))
    }
    // The package's own notice first, then the ones of the code it bundles.
    return found.sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
}

/// The comment a source file opens with, which is where an embedded licence lives.
func leadingComment(_ source: String) -> String? {
    let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("/*"), let end = text.range(of: "*/") else { return nil }
    return String(text[text.index(text.startIndex, offsetBy: 2)..<end.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("usage: generate-acknowledgements.swift <Package.resolved> <checkouts directory> <output.json>")
}
let resolvedURL = URL(filePath: arguments[1])
let checkouts = URL(filePath: arguments[2], directoryHint: .isDirectory)
let output = URL(filePath: arguments[3])

let resolved: Resolved
do {
    resolved = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: resolvedURL))
} catch {
    fail("can't read \(resolvedURL.path): \(error)")
}

var packages: [Acknowledgements.Package] = []
for pin in resolved.pins {
    let name = repositoryName(pin.location)
    let checkout = checkouts.appending(path: name, directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: checkout.path) else {
        fail("no checkout of \(name) in \(checkouts.path); resolve the packages first")
    }
    var notices: [Acknowledgements.Notice] = []
    for file in noticeFiles(in: checkout) {
        let text = (try? String(contentsOf: checkout.appending(path: file), encoding: .utf8)) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { notices.append(.init(file: file, text: trimmed)) }
    }
    for file in embeddedNotices[name] ?? [] {
        guard let source = try? String(contentsOf: checkout.appending(path: file), encoding: .utf8),
              let comment = leadingComment(source)
        else { fail("\(name)/\(file) no longer opens with its licence; update embeddedNotices") }
        notices.append(.init(file: file, text: comment))
    }
    guard !notices.isEmpty else { fail("found no licence for \(name)") }
    let url = pin.location.hasSuffix(".git") ? String(pin.location.dropLast(4)) : pin.location
    packages.append(.init(
        name: name,
        version: pin.state.version ?? String(pin.state.revision.prefix(7)),
        url: url,
        notices: notices
    ))
}
packages.sort { $0.name.lowercased() < $1.name.lowercased() }

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
do {
    try encoder.encode(Acknowledgements(packages: packages)).write(to: output, options: .atomic)
} catch {
    fail("can't write \(output.path): \(error)")
}
print("\(packages.count) packages, \(packages.reduce(0) { $0 + $1.notices.count }) notices")
