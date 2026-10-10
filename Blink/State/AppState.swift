import Foundation
import SwiftUI

@MainActor
@Observable
final class AppState {
    var servers: [DevServer] = []
    var ignoredServers: [DevServer] = []
    var simulators: [Simulator] = []
    private var isScanning = false
    var isInitialLoad = true
    var lastEvent: BlinkEvent = .idle

    var restartStates: [Int: RestartState] = [:]

    var simulatorRestartStates: [String: RestartState] = [:]

    // The panel is the only place where live numbers matter, so it polls fast
    // while open and idles slowly while closed — the menu bar icon only needs
    // to know whether anything runs at all, not every second.
    private static let activePollingInterval: TimeInterval = 2.0
    private static let idlePollingInterval: TimeInterval = 10.0

    private static let ignoredKeysKey = "ignoredServerKeys"

    private var timer: Timer?
    private var killedPIDs: Set<Int> = []

    // Whether the panel is on screen; drives the polling cadence. Must be set
    // on the main thread.
    private var isPanelVisible = false

    // Resolved dev servers by PID. A running process's args and cwd never
    // change, so each PID is resolved once and reused on every later poll
    // instead of spawning ps + lsof per server every cycle.
    private var serverCache: [Int: DevServer] = [:]

    // Keyed by the killed PID, not the port: a port that never falls silent
    // would otherwise stay suppressed forever.
    private var killedPorts: [Int: Int] = [:]
    private var killedSimUDIDs: Set<String> = []

    // Server identity keys hidden from the active list and every count, even
    // while their processes run. Persisted across launches.
    private var ignoredKeys: Set<String> = []

    private var relaunched: [Int: RelaunchedServer] = [:]

    private(set) var isActive: Bool = false
    var totalCount: Int { servers.count + simulators.count }

    // MARK: - Blink Events

    enum BlinkEvent: Equatable {
        case idle
        case active
        case scanning
        case newDetected
        case killed
        case restarting
        case failed
    }

    // MARK: - Restart State

    enum RestartState: Equatable {
        case restarting
        case failed(String)
    }

    // MARK: - Lifecycle

    init() {
        ignoredKeys = Set(
            UserDefaults.standard.stringArray(forKey: Self.ignoredKeysKey) ?? []
        )
        startPolling()
    }

    // MARK: - Polling

    func startPolling() {
        Task { await refresh() }
        scheduleNextPoll()
    }

    /// Called from the main thread when the panel opens or closes. Re-schedules
    /// the poll timer for the matching cadence; opening also refreshes
    /// immediately so the numbers are never stale on reveal.
    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        scheduleNextPoll()
        if visible { Task { await refresh() } }
    }

    private func scheduleNextPoll() {
        timer?.invalidate()

        let interval = isPanelVisible ? Self.activePollingInterval : Self.idlePollingInterval
        let newTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] firingTimer in
            // AppState lives for the whole app, so this is a formality — but
            // if it ever went away, the run loop would keep this timer firing
            // forever. A deinit can't invalidate it (deinit is nonisolated),
            // so the timer retires itself instead.
            guard let self else {
                firingTimer.invalidate()
                return
            }
            Task { await self.refresh() }
        }
        // Let the system coalesce fires with other timers; firing to the
        // millisecond buys nothing for a status readout.
        newTimer.tolerance = interval / 4
        timer = newTimer
    }

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let previousCount = totalCount

        async let scannedServers = scanServers()
        async let scannedSims = SimulatorMonitor.scan()

        let (newServers, newSims) = await (scannedServers, scannedSims)

        let activePIDs = Set(newServers.map(\.pid))
        killedPIDs = killedPIDs.intersection(activePIDs)
        killedPorts = killedPorts.filter { activePIDs.contains($0.value) }
        let activeSimUDIDs = Set(newSims.map(\.id))
        killedSimUDIDs = killedSimUDIDs.intersection(activeSimUDIDs)

        let filteredServers = newServers.filter {
            !killedPIDs.contains($0.pid) && killedPorts[$0.port] == nil
        }
        let filteredSims = newSims.filter { !killedSimUDIDs.contains($0.id) }

        // Ignored servers never reach the active list or the counts, even
        // while they run; they surface in the collapsed ignored section.
        let activeServers = filteredServers.filter { !ignoredKeys.contains($0.ignoreKey) }
        let runningIgnored = filteredServers.filter { ignoredKeys.contains($0.ignoreKey) }

        clearStaleFailures(among: activeServers)
        let mergedServers = preservingRestartingRows(activeServers)

        if servers != mergedServers {
            servers = mergedServers
        }
        if ignoredServers != runningIgnored {
            ignoredServers = runningIgnored
        }
        if simulators != filteredSims {
            simulators = filteredSims
        }
        if isInitialLoad {
            isInitialLoad = false
        }

        let nowActive = totalCount > 0
        if isActive != nowActive {
            isActive = nowActive
        }

        if totalCount > previousCount {
            lastEvent = .newDetected
            try? await Task.sleep(for: .seconds(0.6))
        }

        guard !hasRestartInFlight else { return }

        let newEvent: BlinkEvent = totalCount > 0 ? .active : .idle
        if lastEvent != newEvent {
            lastEvent = newEvent
        }
    }

    // MARK: - Scanning

    func scanServers() async -> [DevServer] {
        let devPorts = ServerScanner.devPorts(from: await PortScanner.scan())

        // A dead PID never comes back, so the cache can be pruned every scan.
        let activePIDs = Set(devPorts.map(\.pid))
        serverCache = serverCache.filter { activePIDs.contains($0.key) }

        // Only new PIDs (or a PID that switched ports) pay for resolution;
        // everything else reuses its already-resolved metadata.
        let unresolved = devPorts.filter { serverCache[$0.pid]?.port != $0.port }
        for server in await ServerScanner.resolve(ports: unresolved) {
            serverCache[server.pid] = server
        }

        return devPorts.compactMap { serverCache[$0.pid] }.sorted { $0.port < $1.port }
    }

    private var hasRestartInFlight: Bool {
        restartStates.values.contains(.restarting)
            || simulatorRestartStates.values.contains(.restarting)
    }

    private func clearStaleFailures(among scanned: [DevServer]) {
        for server in scanned {
            if case .failed = restartStates[server.port] {
                restartStates[server.port] = nil
            }
        }
    }

    private func preservingRestartingRows(_ scanned: [DevServer]) -> [DevServer] {
        guard !restartStates.isEmpty else { return scanned }

        var merged = scanned
        for (port, _) in restartStates where !merged.contains(where: { $0.port == port }) {
            if let previous = servers.first(where: { $0.port == port }) {
                merged.append(previous)
            }
        }
        return merged.sorted { $0.port < $1.port }
    }

    // MARK: - Actions

    func killServer(_ server: DevServer) {
        lastEvent = .killed
        restartStates[server.port] = nil
        killedPIDs.insert(server.pid)
        killedPorts[server.port] = server.pid
        withAnimation(.easeOut(duration: 0.3)) {
            servers.removeAll { $0.port == server.port }
        }
        killProcessTree(pid: server.pid)
    }

    func dismissFailed(_ server: DevServer) {
        restartStates[server.port] = nil
        withAnimation(.easeOut(duration: 0.3)) {
            servers.removeAll { $0.port == server.port }
        }
    }

    // MARK: - Ignoring

    func ignoreServer(_ server: DevServer) {
        ignoredKeys.insert(server.ignoreKey)
        saveIgnoredKeys()
        restartStates[server.port] = nil
        withAnimation(.easeOut(duration: 0.3)) {
            servers.removeAll { $0.id == server.id }
            ignoredServers.append(server)
            ignoredServers.sort { $0.port < $1.port }
        }
    }

    func unignoreServer(_ server: DevServer) {
        ignoredKeys.remove(server.ignoreKey)
        saveIgnoredKeys()
        withAnimation(.easeOut(duration: 0.3)) {
            ignoredServers.removeAll { $0.id == server.id }
            // Still running? Bring it straight back instead of waiting for
            // the next poll to rediscover it.
            if !servers.contains(where: { $0.id == server.id }) {
                servers.append(server)
                servers.sort { $0.port < $1.port }
            }
        }
    }

    private func saveIgnoredKeys() {
        UserDefaults.standard.set(
            ignoredKeys.sorted(),
            forKey: Self.ignoredKeysKey
        )
    }

    func restartApp(in simulator: Simulator) {
        guard let app = simulator.runningApp,
              simulatorRestartStates[simulator.id] != .restarting else { return }

        lastEvent = .restarting
        withAnimation(.easeOut(duration: 0.2)) {
            simulatorRestartStates[simulator.id] = .restarting
        }

        Task {
            let failure = await SimulatorMonitor.relaunchApp(
                udid: simulator.id,
                bundleID: app.bundleID
            )
            finishSimulatorRestart(udid: simulator.id, failure: failure)
        }
    }

    private func finishSimulatorRestart(udid: String, failure: String?) {
        withAnimation(.easeOut(duration: 0.25)) {
            self.simulatorRestartStates[udid] = failure.map { .failed($0) }
            if failure != nil { self.lastEvent = .failed }
        }
    }

    func dismissSimulatorFailure(_ simulator: Simulator) {
        withAnimation(.easeOut(duration: 0.25)) {
            simulatorRestartStates[simulator.id] = nil
        }
    }

    func stopSimulator(_ simulator: Simulator) {
        lastEvent = .killed
        simulatorRestartStates[simulator.id] = nil
        killedSimUDIDs.insert(simulator.id)
        withAnimation(.easeOut(duration: 0.3)) {
            simulators.removeAll { $0.id == simulator.id }
        }
        Task {
            await SimulatorMonitor.shutdown(udid: simulator.id)
        }
    }

    func stopAllServers() {
        lastEvent = .killed

        for server in servers {
            restartStates[server.port] = nil
            killedPIDs.insert(server.pid)
            killedPorts[server.port] = server.pid
            killProcessTree(pid: server.pid)
        }

        cascadeRemoval(count: servers.count) { self.servers.removeFirst() }
    }

    func shutDownAllSimulators() {
        lastEvent = .killed

        for simulator in simulators {
            simulatorRestartStates[simulator.id] = nil
            killedSimUDIDs.insert(simulator.id)
        }

        Task { await SimulatorMonitor.shutdownAll() }
        cascadeRemoval(count: simulators.count) { self.simulators.removeFirst() }
    }

    private func cascadeRemoval(count: Int, removeFirst: @escaping () -> Void) {
        let stagger = 0.1

        Task {
            for index in 0..<count {
                if index > 0 {
                    try? await Task.sleep(for: .seconds(stagger))
                }
                withAnimation(.easeOut(duration: 0.25)) { removeFirst() }
            }

            try? await Task.sleep(for: .seconds(0.3))
            self.lastEvent = totalCount > 0 ? .active : .idle
        }
    }

    private func killProcessTree(pid: Int) {
        let p = pid_t(pid)
        kill(p, SIGTERM)
        Task {
            _ = await Shell.run("/usr/bin/pkill", arguments: ["-TERM", "-P", "\(pid)"])

            try? await Task.sleep(for: .seconds(1))
            kill(p, SIGKILL)
            _ = await Shell.run("/usr/bin/pkill", arguments: ["-KILL", "-P", "\(pid)"])
        }
    }

    func openInBrowser(_ server: DevServer) {
        guard let url = server.localhostURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Restart

    private static let portFreeTimeout: TimeInterval = 6
    private static let portReturnTimeout: TimeInterval = 30
    private static let exitGracePeriod: TimeInterval = 1

    private enum RelaunchOutcome {
        case listening
        case exited
        case timedOut
    }

    func restartServer(_ server: DevServer) {
        guard restartStates[server.port] != .restarting else { return }

        lastEvent = .restarting
        withAnimation(.easeOut(duration: 0.2)) {
            restartStates[server.port] = .restarting
        }

        Task { await performRestart(server) }
    }

    private func performRestart(_ server: DevServer) async {
        guard !server.projectPath.isEmpty,
              let target = await ProcessResolver.relaunchTarget(
                  pid: server.pid,
                  projectPath: server.projectPath
              ) else {
            finishRestart(port: server.port, failure: "Couldn't read the original command.")
            return
        }

        killProcessTree(pid: target.pid)
        killedPIDs.insert(server.pid)
        killedPIDs.insert(target.pid)

        guard await waitForPort(server.port, listening: false, timeout: Self.portFreeTimeout) else {
            finishRestart(port: server.port, failure: "Port \(server.port) never freed up.")
            return
        }

        killedPIDs.remove(server.pid)
        killedPIDs.remove(target.pid)
        killedPorts[server.port] = nil

        let relaunchedServer: RelaunchedServer
        do {
            relaunchedServer = try RelaunchedServer(
                executable: target.executablePath,
                arguments: target.arguments,
                directory: server.projectPath
            )
        } catch {
            finishRestart(port: server.port, failure: "Couldn't relaunch: \(error.localizedDescription)")
            return
        }

        relaunched[server.port] = relaunchedServer

        let outcome = await waitForServer(relaunchedServer, port: server.port)
        let tail = relaunchedServer.outputTail()

        switch outcome {
        case .listening:
            finishRestart(port: server.port, failure: nil)

        case .exited:
            finishRestart(
                port: server.port,
                failure: tail.isEmpty ? relaunchedServer.exitDescription : tail
            )

        case .timedOut:
            finishRestart(
                port: server.port,
                failure: tail.isEmpty
                    ? "Running, but nothing is listening on \(server.port) yet."
                    : tail
            )
        }
    }

    private func finishRestart(port: Int, failure: String?) {
        withAnimation(.easeOut(duration: 0.25)) {
            if let failure {
                self.restartStates[port] = .failed(failure)
                self.lastEvent = .failed
            } else {
                self.restartStates[port] = nil
            }
        }
    }

    private func waitForServer(_ relaunched: RelaunchedServer, port: Int) async -> RelaunchOutcome {
        let deadline = Date().addingTimeInterval(Self.portReturnTimeout)

        while Date() < deadline {
            if await isPortListening(port) { return .listening }

            if !relaunched.isRunning {
                try? await Task.sleep(for: .seconds(Self.exitGracePeriod))
                return await isPortListening(port) ? .listening : .exited
            }

            try? await Task.sleep(for: .seconds(0.4))
        }

        return await isPortListening(port) ? .listening : .timedOut
    }

    private func waitForPort(_ port: Int, listening: Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let interval: TimeInterval = 0.4

        while Date() < deadline {
            if await isPortListening(port) == listening { return true }
            try? await Task.sleep(for: .seconds(interval))
        }
        return await isPortListening(port) == listening
    }

    private func isPortListening(_ port: Int) async -> Bool {
        let output = await Shell.run(
            "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        )
        return !(output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}
