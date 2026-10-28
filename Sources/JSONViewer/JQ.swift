import Foundation

/// Runs filters through the jq binary embedded in the app bundle (see build.sh).
enum JQ {
    static let binary: String? = [Bundle.main.path(forResource: "jq", ofType: nil), "/usr/bin/jq"]
        .compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Returns one JSON value per jq output.
    static func run(_ filter: String, input: String) async throws -> [JSON] {
        guard let binary else { throw Failure(message: "jq is missing from the app bundle — rebuild with ./build.sh") }
        // Temp file instead of stdin: avoids pipe deadlocks on large documents.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jsonviewer-\(UUID().uuidString).json")
        try input.write(to: file, atomically: false, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-c", filter, file.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        return try await withTaskCancellationHandler {
            try p.run()
            // Read both pipes concurrently so neither fills up and blocks jq.
            async let o = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
            async let e = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
            let (stdout, stderr) = await (o, e)
            p.waitUntilExit()
            try Task.checkCancellation()
            if p.terminationStatus != 0 {
                let first = String(decoding: stderr, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "jq failed"
                throw Failure(message: first
                    .replacingOccurrences(of: #"jq: error( \(at [^)]*\))?: "#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: " (Unix shell quoting issues?)", with: ""))
            }
            // -c prints one value per line; newlines inside strings are escaped.
            return try String(decoding: stdout, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { try JSONParser.parse(String($0)) }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }

    struct Failure: Error { var message: String }
}
