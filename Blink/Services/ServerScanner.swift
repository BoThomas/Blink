import Foundation

enum ServerScanner {
    private static let devCommands: Set<String> = [
        "node", "python", "python3", "ruby", "cargo",
        "go", "php", "java", "deno", "bun", "tsx", "npx",
        "next-serv", "uvicorn", "gunicorn", "puma"
    ]

    // MARK: - Discovery

    static func devPorts(from ports: [ListeningPort]) -> [ListeningPort] {
        let devPorts = ports.filter { devCommands.contains($0.command.lowercased()) }

        var seenPorts = Set<Int>()
        var seenPIDs = Set<Int>()
        return devPorts.filter { port in
            seenPorts.insert(port.port).inserted && seenPIDs.insert(port.pid).inserted
        }
    }

    // MARK: - Resolution

    // Resolves the given ports into dev servers with one batched `ps` and one
    // batched `lsof` call instead of a process spawn per server. Only called
    // for PIDs not yet in AppState's cache — a running process's args and cwd
    // don't change. A PID whose `ps` line is missing (it died between the port
    // scan and this call) stays uncached and is retried next poll, which is
    // exactly right for a process on its way out.
    static func resolve(ports: [ListeningPort]) async -> [DevServer] {
        guard !ports.isEmpty else { return [] }

        let pidList = ports.map { String($0.pid) }.joined(separator: ",")
        async let argsOutput = Shell.run("/bin/ps", arguments: ["-p", pidList, "-o", "pid=,args="])
        async let cwdOutput = Shell.run("/usr/sbin/lsof", arguments: ["-d", "cwd", "-a", "-p", pidList, "-Fn"])

        let argumentsByPID = parseArguments(await argsOutput ?? "")
        let workingDirectoriesByPID = parseWorkingDirectories(await cwdOutput ?? "")

        return ports.compactMap { port in
            // Args are required; cwd is not. lsof cannot read the working
            // directory of other users' processes (a sudo-launched server),
            // and those servers show up with an empty path, like before.
            guard let arguments = argumentsByPID[port.pid] else {
                return nil
            }
            let workingDirectory = workingDirectoriesByPID[port.pid] ?? ""

            let info = ResolvedProcess(
                pid: port.pid,
                arguments: arguments,
                workingDirectory: workingDirectory
            )

            return DevServer(
                pid: port.pid,
                port: port.port,
                command: port.command,
                framework: ProcessResolver.detectFramework(from: info),
                projectName: ProcessResolver.resolveProjectName(from: info.workingDirectory),
                projectPath: info.workingDirectory
            )
        }
    }
}

// MARK: - Parsing

private extension ServerScanner {
    // Lines look like "  1234 node server.js": PID, whitespace, full args.
    // A PID line without args (dead process) is dropped, so it is retried on
    // the next poll instead of being cached.
    static func parseArguments(_ output: String) -> [Int: String] {
        var results: [Int: String] = [:]

        for line in output.split(separator: "\n") {
            let trimmed = line.drop(while: \.isWhitespace)
            guard let split = trimmed.firstIndex(where: \.isWhitespace),
                  let pid = Int(trimmed[..<split]) else { continue }
            results[pid] = String(trimmed[trimmed.index(after: split)...])
        }

        return results
    }

    // Field output switches PID on every "p" line; the "n/" line that follows
    // is that process's working directory (cwd comes through -d cwd).
    static func parseWorkingDirectories(_ output: String) -> [Int: String] {
        var results: [Int: String] = [:]
        var currentPID: Int?

        for line in output.split(separator: "\n") {
            if line.first == "p" {
                currentPID = Int(line.dropFirst())
            } else if line.hasPrefix("n/"), let currentPID {
                results[currentPID] = String(line.dropFirst())
            }
        }

        return results
    }
}
