import CleanupTraining
import CryptoKit
import Foundation
import Shared

/// Prepared inputs keep every candidate, including ones the runtime cannot accept. Report
/// those explicitly instead of silently removing difficult ASR examples from the dataset.
func validatePreparedData(directory: URL, deep: Bool, report: URL?) throws -> Bool {
    struct Header: Decodable {
        let id: String?
        let familyID: String?
        let split: String?
        let raw: String
        let reviewRequired: Bool?
        let trainingWeight: Int?

        enum CodingKeys: String, CodingKey {
            case id, split, raw
            case familyID = "family_id"
            case reviewRequired = "review_required"
            case trainingWeight = "training_weight"
        }
    }
    struct Issue: Encodable {
        let file: String
        let line: Int
        let reasons: [String]
    }
    struct Audit: Encodable {
        let kind: String
        let counts: [String: Int]
        let files: [String: String]
        let ready: Bool
        let issues: [Issue]
    }

    var counts: [String: Int] = [:]
    var files: [String: String] = [:]
    var issues: [Issue] = []
    var families: [String: String] = [:]
    var inputs: [String: String] = [:]
    var ids: Set<String> = []
    let metadataFile = directory.appending(path: "preparation-report.json")
    if FileManager.default.fileExists(atPath: metadataFile.path) {
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataFile)) as? [String: Any]
        if let stage = metadata?["stage"] as? String, ["speech-seeds", "stress-data"].contains(stage) {
            issues.append(Issue(file: metadataFile.path, line: 0, reasons: ["\(stage) is not a reconciled training dataset; synthesize and transcribe speech seeds first"]))
        }
    }
    let heldOut: Set<String>
    if deep {
        heldOut = try heldOutRaws().union(mediumTestRaws())
    } else {
        heldOut = Set(try Paths.curatedFiles(.test).flatMap { try TrainingData.read(from: $0) }
            .map { EditDistance.normalize($0.raw) })
    }
    for split in DataSplit.allCases {
        let name = split.rawValue
        let file = directory.appending(path: "\(name).jsonl")
        let content = try String(contentsOf: file, encoding: .utf8)
        let hash = SHA256.hash(data: Data(content.utf8))
        files["\(name).jsonl"] = hash.map { String(format: "%02x", $0) }.joined()
        let lines = content.components(separatedBy: "\n").enumerated().filter {
            !$0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let headers = try lines.map { try JSONDecoder().decode(Header.self, from: Data($0.element.utf8)) }
        let problems = try lines.map { line -> [String] in
            let data = Data(line.element.utf8)
            if deep {
                return DeepExampleValidator().problems(in: try JSONDecoder().decode(DeepExample.self, from: data))
            }
            return ExampleValidator().problems(in: try JSONDecoder().decode(TrainingExample.self, from: data))
        }
        counts[name] = headers.count
        if headers.isEmpty { issues.append(Issue(file: name, line: 0, reasons: ["empty split"])) }
        for (index, header) in headers.enumerated() {
            var reasons = problems[index]
            if let id = header.id, !id.isEmpty {
                if !ids.insert(id).inserted { reasons.append("duplicate example id") }
            } else { reasons.append("missing id") }
            if let family = header.familyID, !family.isEmpty {
                if let previous = families[family], previous != name {
                    reasons.append("source family also occurs in \(previous)")
                }
                families[family] = name
            } else { reasons.append("missing family_id") }
            if header.split != name { reasons.append("wrong split metadata") }
            if header.reviewRequired == true { reasons.append("ASR changed words; this pair needs a reviewed target") }
            if !(1...10).contains(header.trainingWeight ?? 1) { reasons.append("training_weight must be an integer from 1 to 10") }
            let normalized = EditDistance.normalize(header.raw)
            if let previous = inputs[normalized], previous != name {
                reasons.append("normalized input also occurs in \(previous)")
            }
            inputs[normalized] = name
            if split != .test, heldOut.contains(normalized) {
                reasons.append("input is held out for evaluation")
            }
            if !reasons.isEmpty { issues.append(Issue(file: file.path, line: lines[index].offset + 1, reasons: reasons)) }
        }
        print("\(file.path): \(headers.count) candidate examples")
    }
    let audit = Audit(kind: deep ? "deep" : "medium", counts: counts, files: files, ready: issues.isEmpty, issues: issues)
    if let report { try writeJSON(audit, to: report) }
    print(issues.isEmpty ? "Prepared data passes all checks." : "\(issues.count) rows need attention; candidates have not been removed.")
    return issues.isEmpty
}

private struct PreparedWeight: Decodable { let training_weight: Int? }

/// Preserve the shipped curated x2 recipe and the placeholder family's contribution when
/// multiple recognizers supply an input for each spoken source. Validation/test rows stay x1.
func expandPreparedData<T>(_ examples: [T], directory: URL, split: DataSplit) throws -> [T] {
    let file = directory.appending(path: "\(split.rawValue).jsonl")
    let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let weights = try lines.map { try JSONDecoder().decode(PreparedWeight.self, from: Data($0.utf8)).training_weight ?? 1 }
    guard weights.count == examples.count, weights.allSatisfy({ (1...10).contains($0) }) else { throw TrainError.invalidData }
    return zip(examples, weights).flatMap { Array(repeating: $0.0, count: $0.1) }
}

/// Fingerprint the exact candidate files used by a prepared-data training run.
func recordPreparedData(_ directory: URL, output: URL) throws {
    var files: [String: String] = [:]
    for split in DataSplit.allCases {
        let name = "\(split.rawValue).jsonl"
        let hash = SHA256.hash(data: try Data(contentsOf: directory.appending(path: name)))
        files[name] = hash.map { String(format: "%02x", $0) }.joined()
    }
    try writeJSON(files, to: output.appending(path: "dataset-sha256.json"))
}
