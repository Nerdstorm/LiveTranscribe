@testable import DictationUI
import Foundation
import Testing

/// The waiting script that reopens the app, run with `/bin/echo` in place of `open`.
@Suite("AppRelauncher")
struct AppRelauncherTests {
    /// Runs the script to the end and returns what it printed.
    private func run(waitingFor pid: Int32, echoing argument: String) async throws -> String {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = AppRelauncher.arguments(waitingFor: pid, thenRunning: "/bin/echo", with: argument)
        let output = Pipe()
        script.standardOutput = output
        try await runToEnd(script)
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func runToEnd(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// A process that has already exited, so the script need not wait.
    private func exitedProcess() async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try await runToEnd(process)
        return process.processIdentifier
    }

    @Test("The path reaches the command as one argument, whatever it holds", arguments: [
        "/Applications/Live Transcribe.app",
        #"/Users/x/My "Apps"/Live Transcribe.app"#,
        "/tmp/$(echo injected)/`echo x`/it's.app",
        // echo joins split words with one space, so only these show the path was split or expanded.
        "/Applications/Two  Spaces.app",
        "/bin/*",
    ])
    func passesThePathIntact(path: String) async throws {
        let printed = try await run(waitingFor: exitedProcess(), echoing: path)
        #expect(printed == path + "\n")
    }

    @Test func waitsForTheProcessToExitFirst() async throws {
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sleep")
        running.arguments = ["0.3"]
        try running.run()

        let printed = try await run(waitingFor: running.processIdentifier, echoing: "reopened")

        #expect(printed == "reopened\n")
        #expect(kill(running.processIdentifier, 0) == -1, "the command ran only once the process had gone")
    }
}
