import Foundation
import Observation
import os

@Observable
@MainActor
final class BammSession {
    enum State: String, Sendable { case idle, streaming, stopped, error }

    let mode: BackendMode
    private(set) var state: State = .idle
    private(set) var lastError: String? = nil

    let sessionId: String = UUID().uuidString
    let pendingFrame = PendingFrameBox()

    private nonisolated let localClient: BammClient?
    private var pollTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    @ObservationIgnored
    private let queueBox = OSAllocatedUnfairLock<[JointFrame]>(initialState: [])

    private nonisolated let hostedClient: HostedBammClient?
    private var hostedTask: Task<Void, Never>?

    @ObservationIgnored
    private nonisolated(unsafe) var onDeviceClient: OnDeviceBammClient?
    @ObservationIgnored
    private var onDeviceTask: Task<Void, Never>?

    static func local(baseUrl: String) -> BammSession {
        BammSession(mode: .local,
                    localClient: BammClient(baseUrl: baseUrl),
                    hostedClient: nil)
    }

    static func hosted(baseUrl: String) -> BammSession {
        BammSession(mode: .hosted,
                    localClient: nil,
                    hostedClient: HostedBammClient(baseUrl: baseUrl))
    }

    static func onDevice() -> BammSession {
        BammSession(mode: .onDevice, localClient: nil, hostedClient: nil)
    }

    static func build(mode: BackendMode, baseUrl: String) -> BammSession {
        switch mode {
        case .local:    return .local(baseUrl: baseUrl)
        case .hosted:   return .hosted(baseUrl: baseUrl)
        case .onDevice: return .onDevice()
        }
    }

    private init(mode: BackendMode, localClient: BammClient?, hostedClient: HostedBammClient?) {
        self.mode = mode
        self.localClient = localClient
        self.hostedClient = hostedClient
    }

    func clearError() { lastError = nil }

    func start(_ text: String) {
        switch mode {
        case .local:    startLocal(text)
        case .hosted:   startHosted(text)
        case .onDevice: startOnDevice(text)
        }
    }

    func updateText(_ text: String) { start(text) }

    func reset() {
        switch mode {
        case .local:    resetLocal()
        case .hosted:   resetHosted()
        case .onDevice: resetOnDevice()
        }
    }

    func shutdown() {
        reset()
    }

    // MARK: - Local mode

    private func startLocal(_ text: String) {
        Task { await self.startOrOverride(text, retryDepth: 0) }
        queueBox.withLock { $0.removeAll(keepingCapacity: true) }
    }

    private func startOrOverride(_ text: String, retryDepth: Int) async {
        guard let client = self.localClient else { return }
        let sid = self.sessionId
        if state == .streaming {
            do {
                try await client.updateText(sessionId: sid, text: text)
                self.lastError = nil
            } catch {
                if retryDepth == 0, isAlreadyRunning(error) || isNotActive(error) {
                    try? await client.reset(sessionId: sid)
                    self.state = .idle
                    await self.startOrOverride(text, retryDepth: retryDepth + 1)
                } else {
                    self.state = .error
                    self.lastError = humanize("Update text", error)
                }
            }
            return
        }

        do {
            try await client.start(sessionId: sid, text: text)
            self.state = .streaming
            self.lastError = nil
            startLoopsIfNeeded()
        } catch {
            if isAlreadyRunning(error) {
                self.state = .streaming
                self.lastError = nil
                startLoopsIfNeeded()
                _ = try? await client.updateText(sessionId: sid, text: text)
            } else if retryDepth == 0, isConflict(error) || isNotActive(error) {
                try? await client.reset(sessionId: sid)
                await self.startOrOverride(text, retryDepth: retryDepth + 1)
            } else {
                self.state = .error
                self.lastError = humanize("Start", error)
            }
        }
    }

    private func resetLocal() {
        let sid = sessionId
        let client = self.localClient
        Task.detached { try? await client?.reset(sessionId: sid) }
        pollTask?.cancel(); pollTask = nil
        playbackTask?.cancel(); playbackTask = nil
        queueBox.withLock { $0.removeAll() }
        pendingFrame.clear()
        state = .stopped
    }

    private func startLoopsIfNeeded() {
        if pollTask == nil || pollTask?.isCancelled == true {
            pollTask = Task { await self.pollLoop() }
        }
        if playbackTask == nil || playbackTask?.isCancelled == true {
            playbackTask = Task { await self.playbackLoop() }
        }
    }

    private func pollLoop() async {
        var consecutiveFailures = 0
        guard let client = self.localClient else { return }
        let sid = self.sessionId
        while !Task.isCancelled, self.state == .streaming {
            var frames: [JointFrame] = []
            var failed: Error? = nil
            do {
                frames = try await client.getFrame(sessionId: sid, count: 8)
            } catch {
                try? await Task.sleep(nanoseconds: 120_000_000)
                do {
                    frames = try await client.getFrame(sessionId: sid, count: 8)
                } catch {
                    failed = error
                }
            }
            if let failed {
                consecutiveFailures += 1
                if consecutiveFailures >= 6 {
                    self.lastError = humanize("Server stream", failed)
                    self.state = .error
                }
            } else {
                consecutiveFailures = 0
                if !frames.isEmpty {
                    let captured = frames
                    queueBox.withLock { $0.append(contentsOf: captured) }
                }
                if self.lastError != nil { self.lastError = nil }
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    private func playbackLoop() async {
        let frameNs: UInt64 = 1_000_000_000 / 30
        while !Task.isCancelled, self.state == .streaming {
            let next: JointFrame? = queueBox.withLock { queue -> JointFrame? in
                if queue.isEmpty { return nil }
                return queue.removeFirst()
            }
            if let next { pendingFrame.set(next) }
            try? await Task.sleep(nanoseconds: frameNs)
        }
    }

    // MARK: - Hosted mode

    private func startHosted(_ text: String) {
        hostedTask?.cancel(); hostedTask = nil
        lastError = nil
        let client = hostedClient
        hostedTask = Task { [weak self] in
            guard let self else { return }
            await self.hostedFlow(client: client, text: text)
        }
    }

    private func hostedFlow(client: HostedBammClient?, text: String) async {
        guard let client else { return }
        do {
            let bvh = try await client.generate(textPrompt: text)
            if Task.isCancelled { return }
            let motion: BvhMotion
            do {
                motion = try BvhParser.parse(bvh)
            } catch {
                if Task.isCancelled { return }
                print("[BammSession] BVH parse failed: \(error)")
                self.state = .error
                self.lastError = humanize("Parse BVH", error)
                return
            }
            if motion.frames.isEmpty {
                self.state = .error
                self.lastError = "Generate — server returned no frames."
                return
            }
            self.state = .streaming
            await hostedPlay(motion)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            self.state = .error
            self.lastError = humanize("Generate", error)
        }
    }

    private func hostedPlay(_ motion: BvhMotion) async {
        let frameNs = UInt64(max(motion.frameTime, 1.0 / 240.0) * 1_000_000_000)
        let frames = motion.frames
        var i = 0
        while !Task.isCancelled {
            pendingFrame.set(frames[i % frames.count])
            i += 1
            try? await Task.sleep(nanoseconds: frameNs)
        }
    }

    private func resetHosted() {
        hostedTask?.cancel(); hostedTask = nil
        pendingFrame.clear()
        state = .stopped
    }

    // MARK: - On-device mode

    private func startOnDevice(_ text: String) {
        onDeviceTask?.cancel(); onDeviceTask = nil
        lastError = nil
        if onDeviceClient == nil {
            do {
                onDeviceClient = try OnDeviceBammClient(precision: GenerationSettings.shared.precision)
            } catch {
                state = .error
                lastError = humanize("Init on-device", error)
                return
            }
        }
        let client = onDeviceClient
        onDeviceTask = Task { [weak self] in
            guard let self else { return }
            await self.onDeviceFlow(client: client, text: text)
        }
    }

    private func onDeviceFlow(client: OnDeviceBammClient?, text: String) async {
        guard let client else { return }
        do {
            // Snapshot knobs so a slider drag mid-flight doesn't mutate the live pipeline.
            let sampling = await MainActor.run { GenerationSettings.shared.snapshot() }
            let motion = try await client.generate(textPrompt: text, sampling: sampling)
            if Task.isCancelled { return }
            if motion.frames.isEmpty {
                self.state = .error
                self.lastError = "On-device — generated zero frames."
                return
            }
            self.state = .streaming
            await hostedPlay(motion)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            self.state = .error
            self.lastError = humanize("On-device generate", error)
        }
    }

    private func resetOnDevice() {
        onDeviceTask?.cancel(); onDeviceTask = nil
        pendingFrame.clear()
        state = .stopped
    }
}

// MARK: - Error classification

private func isAlreadyRunning(_ e: Error) -> Bool {
    let m = String(describing: e).lowercased()
    return m.contains("already running") || (m.contains("http 400") && m.contains("generation"))
}

private func isConflict(_ e: Error) -> Bool {
    let m = String(describing: e).lowercased()
    return m.contains("http 409") || m.contains("another session")
}

private func isNotActive(_ e: Error) -> Bool {
    let m = String(describing: e).lowercased()
    return m.contains("http 403") || m.contains("not the active session")
}

private func humanize(_ action: String, _ e: Error) -> String {
    let msg = String(describing: e)
    let lower = msg.lowercased()
    if lower.contains("connection refused") || lower.contains("could not connect") || lower.contains("cannot connect") {
        return "\(action) — server not reachable. Make sure BAMM is running and the URL is correct."
    }
    if lower.contains("timeout") || lower.contains("timed out") {
        return "\(action) — server timed out."
    }
    if lower.contains("http 5") {
        return "\(action) — server error: \(msg)"
    }
    return "\(action) failed: \(msg)"
}
