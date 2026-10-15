import Foundation
import Observation
import os

@Observable
@MainActor
final class BammSession {
    enum State: String, Sendable { case idle, streaming, stopped, error }

    let model: BackendModel
    let mode: BackendMode
    private(set) var state: State = .idle
    private(set) var lastError: String? = nil

    private(set) var progressText: String? = nil
    var isGenerating: Bool { progressText != nil }

    private(set) var gemxVideoURL: URL? = nil
    private(set) var gemxCamera: CameraMotion? = nil

    @ObservationIgnored var externalClock: Bool = false

    private(set) var playbackCount: Int = 0
    private(set) var playbackFrame: Int = 0
    private(set) var playbackFrameTime: Double = 1.0 / 30
    var playbackPaused: Bool = false { didSet { if externalClock { overlayTransport?.setPaused(playbackPaused) } } }

    var playbackLoop: Bool = true { didSet { overlayTransport?.setLoop(playbackLoop) } }
    @ObservationIgnored private var playbackFrames: [JointFrame] = []
    @ObservationIgnored private let seekBox = OSAllocatedUnfairLock<Int?>(initialState: nil)

    @ObservationIgnored weak var overlayTransport: PlaybackTransport?

    var playbackDuration: Double { Double(playbackCount) * playbackFrameTime }

    func seek(frame: Int) {
        guard playbackCount > 0 else { return }
        let f = min(max(frame, 0), playbackCount - 1)
        playbackFrame = f
        seekBox.withLock { $0 = f }
        if externalClock { overlayTransport?.seek(to: Double(f) * playbackFrameTime) }
        else if f < playbackFrames.count { pendingFrame.set(playbackFrames[f]) }
    }

    func togglePlayback() { playbackPaused.toggle() }

    func reportPlaybackFrame(_ f: Int) { if f != playbackFrame { playbackFrame = f } }

    private func resetPlayback() {
        playbackFrames = []; playbackCount = 0; playbackFrame = 0; playbackPaused = false
        seekBox.withLock { $0 = nil }
    }

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

    private nonisolated let gemxClient: HostedGemxClient?
    private var gemxTask: Task<Void, Never>?
    @ObservationIgnored
    private nonisolated(unsafe) var onDeviceGemxClient: OnDeviceGemxClient?

    static func local(baseUrl: String, model: BackendModel = .bamm) -> BammSession {
        BammSession(model: model, mode: .local,
                    localClient: BammClient(baseUrl: baseUrl),
                    hostedClient: nil, gemxClient: nil)
    }

    static func hosted(baseUrl: String, model: BackendModel = .bamm) -> BammSession {
        BammSession(model: model, mode: .hosted,
                    localClient: nil,
                    hostedClient: HostedBammClient(baseUrl: baseUrl), gemxClient: nil)
    }

    static func onDevice(model: BackendModel = .bamm) -> BammSession {
        BammSession(model: model, mode: .onDevice, localClient: nil, hostedClient: nil, gemxClient: nil)
    }

    static func gemx(mode: BackendMode, baseUrl: String) -> BammSession {
        BammSession(model: .gemx, mode: mode, localClient: nil, hostedClient: nil,
                    gemxClient: mode == .onDevice ? nil : HostedGemxClient(baseUrl: baseUrl))
    }

    static func build(model: BackendModel, mode: BackendMode, baseUrl: String) -> BammSession {
        if model.takesVideo { return .gemx(mode: mode, baseUrl: baseUrl) }
        switch mode {
        case .local:    return .local(baseUrl: baseUrl, model: model)
        case .hosted:   return .hosted(baseUrl: baseUrl, model: model)
        case .onDevice: return .onDevice(model: model)
        }
    }

    private init(model: BackendModel, mode: BackendMode, localClient: BammClient?,
                 hostedClient: HostedBammClient?, gemxClient: HostedGemxClient?) {
        self.model = model
        self.mode = mode
        self.localClient = localClient
        self.hostedClient = hostedClient
        self.gemxClient = gemxClient
    }

    func clearError() { lastError = nil }

    func start(_ text: String) {
        if model.takesVideo {
            lastError = "\(model.displayName) takes a video, not text — choose a clip and tap Generate."
            return
        }
        switch mode {
        case .local:    startLocal(text)
        case .hosted:   startHosted(text)
        case .onDevice: startOnDevice(text)
        }
    }

    func updateText(_ text: String) { start(text) }

    func reset() {
        if model.takesVideo { resetGemx(); return }
        switch mode {
        case .local:    resetLocal()
        case .hosted:   resetHosted()
        case .onDevice: resetOnDevice()
        }
    }

    func shutdown() {
        reset()
    }

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
        resetPlayback()
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
            await playBvhText(bvh, action: "Generate")
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            self.state = .error
            self.lastError = humanize("Generate", error)
        }
    }

    private func playBvhText(_ bvh: String, action: String) async {
        let motion: BvhMotion
        do {
            let t0 = Date()
            motion = try await Task.detached(priority: .userInitiated) { try BvhParser.parse(bvh) }.value
            NSLog("[GemxAuto] parsed %@ BVH (%d frames) in %.2f s", action, motion.frames.count, Date().timeIntervalSince(t0))
        } catch {
            if Task.isCancelled { return }
            print("[BammSession] BVH parse failed: \(error)")
            self.state = .error
            self.lastError = humanize("Parse BVH", error)
            self.progressText = nil
            return
        }
        if motion.frames.isEmpty {
            self.state = .error
            self.lastError = "\(action) — server returned no frames."
            self.progressText = nil
            return
        }
        self.progressText = nil
        self.state = .streaming
        NSLog("[GemxAuto] playing %d frames (frameTime %.4f)", motion.frames.count, motion.frameTime)
        await hostedPlay(motion)
    }

    private func hostedPlay(_ motion: BvhMotion) async {
        let frameTime = max(motion.frameTime, 1.0 / 240.0)
        let frameNs = UInt64(frameTime * 1_000_000_000)
        let frames = motion.frames
        playbackFrames = frames; playbackCount = frames.count; playbackFrameTime = frameTime
        playbackFrame = 0; playbackPaused = false; seekBox.withLock { $0 = nil }
        var i = 0
        while !Task.isCancelled {
            if let s = seekBox.withLock({ v -> Int? in let s = v; v = nil; return s }) { i = min(max(s, 0), frames.count - 1) }
            if !externalClock && !playbackPaused {
                pendingFrame.set(frames[i])
                playbackFrame = i
                i += 1
                if i >= frames.count {
                    if playbackLoop { i = 0 } else { i = frames.count - 1; playbackPaused = true }
                }
            }
            try? await Task.sleep(nanoseconds: frameNs)
        }
    }

    private func resetHosted() {
        hostedTask?.cancel(); hostedTask = nil
        resetPlayback()
        pendingFrame.clear()
        state = .stopped
    }

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
        resetPlayback()
        pendingFrame.clear()
        state = .stopped
    }

    func startVideo(_ video: PickedVideo) {
        gemxTask?.cancel(); gemxTask = nil
        lastError = nil
        progressText = mode == .onDevice ? "Loading models…" : "Uploading…"
        let options = GemxSettings.shared.snapshot()
        if mode == .onDevice {
            if onDeviceGemxClient == nil {
                do {
                    onDeviceGemxClient = try OnDeviceGemxClient()
                } catch {
                    state = .error
                    lastError = humanize("Init on-device GEM-X", error)
                    progressText = nil
                    return
                }
            }
            let client = onDeviceGemxClient
            gemxTask = Task { [weak self] in
                guard let self else { return }
                await self.gemxOnDeviceFlow(client: client, video: video, options: options)
            }
        } else {
            let client = gemxClient
            gemxTask = Task { [weak self] in
                guard let self else { return }
                await self.gemxHostedFlow(client: client, video: video, options: options)
            }
        }
    }

    private func gemxHostedFlow(client: HostedGemxClient?, video: PickedVideo, options: GemxOptions) async {
        guard let client else { return }
        do {
            let res = try await client.generate(videoURL: video.url, options: options) { [weak self] p in
                Task { @MainActor in
                    guard let self, self.gemxTask?.isCancelled == false else { return }
                    self.progressText = p.state == "uploading" ? "Uploading… \(GemxProgress.mmss(p.elapsedSeconds))" : p.text
                }
            }
            if Task.isCancelled { return }
            NSLog("[GemxAuto] hosted BVH received: %d bytes (incam: %@)", res.bvh.utf8.count, res.bvhIncam == nil ? "no" : "yes")
            if let inc = res.bvhIncam, let cam = res.camera {
                do {
                    let m = try await Task.detached(priority: .userInitiated) { try BvhParser.parse(inc, somaFrame: .camera) }.value
                    if Task.isCancelled { return }
                    self.gemxCamera = CameraMotion(frames: m.frames, frameTime: m.frameTime, camera: cam)
                } catch {
                    NSLog("[GemxAuto] camera-frame BVH parse failed: %@", String(describing: error))
                }
            }
            await playBvhText(res.bvh, action: "GEM-X")
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            self.state = .error
            self.lastError = humanize("GEM-X generate", error)
            self.progressText = nil
        }
    }

    private func gemxOnDeviceFlow(client: OnDeviceGemxClient?, video: PickedVideo, options: GemxOptions) async {
        guard let client else { return }
        do {
            let t0 = Date()
            let out = try await client.generate(videoURL: video.url, options: options) { [weak self] text in
                NSLog("[GemxAuto] %@", text)
                Task { @MainActor in
                    guard let self, self.gemxTask?.isCancelled == false else { return }
                    self.progressText = text
                }
            }
            if Task.isCancelled { return }
            let motion = out.motion
            let timings = client.lastResult?.timings.map { "\($0.key)=\(String(format: "%.1f", $0.value))s" }.sorted().joined(separator: " ") ?? ""
            NSLog("[GemxAuto] done: %d frames in %.1f s (%@)", motion.frames.count, Date().timeIntervalSince(t0), timings)
            if motion.frames.isEmpty {
                self.state = .error
                self.lastError = "On-device GEM-X — produced zero frames."
                self.progressText = nil
                return
            }
            self.gemxCamera = out.camera
            self.progressText = nil
            self.state = .streaming
            await hostedPlay(motion)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            NSLog("[GemxAuto] failed: %@", String(describing: error))
            self.state = .error
            self.lastError = humanize("On-device GEM-X", error)
            self.progressText = nil
        }
    }

    private func resetGemx() {
        gemxTask?.cancel(); gemxTask = nil
        resetPlayback()
        pendingFrame.clear()
        progressText = nil
        gemxCamera = nil
        gemxVideoURL = nil
        state = .stopped
    }
}

@MainActor
protocol PlaybackTransport: AnyObject {
    func seek(to seconds: Double)
    func setPaused(_ paused: Bool)
    func setLoop(_ loop: Bool)
}

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
