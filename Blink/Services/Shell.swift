import Foundation

enum Shell {
    static func run(
        _ path: String,
        arguments: [String] = [],
        mergingErrors: Bool = false
    ) async -> String? {
        await withCheckedContinuation { continuation in
            // Everything below blocks, so it runs off Swift's cooperative
            // thread pool — a burst of concurrent scans would starve it.
            DispatchQueue.global().async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = mergingErrors ? pipe : FileHandle.nullDevice

                var env = ProcessInfo.processInfo.environment
                if let xcodePath = [
                    "/Applications/Xcode.app/Contents/Developer",
                    "/Applications/Xcode-beta.app/Contents/Developer"
                ].first(where: { FileManager.default.fileExists(atPath: $0) }) {
                    env["DEVELOPER_DIR"] = xcodePath
                }
                process.environment = env

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                // Drain stdout while the child is still running. Waiting for
                // exit first deadlocks once the output outgrows the pipe
                // buffer (lsof with many listening services): the child
                // blocks writing, the parent waits forever for it to exit.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }
}
