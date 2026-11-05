import Foundation
import Observation
import UIKit
import MWDATCore
import MWDATCamera
import MWDATDisplay
import MWDATInputs

/// A native button shared by voice routing and the glasses' focus/pinch controls.
struct MendGlassesAction: Sendable, Equatable {
    let id: String
    let label: String
    var enabled = true
}

/// A single DAT session owns both the camera and the flat, native display.
/// The caller supplies already annotated photographs; there are no world anchors.
@Observable @MainActor
final class FixiGlasses {
    private(set) var registered = false
    private(set) var registrationReady = false
    private(set) var available = false
    private(set) var streaming = false
    private(set) var startingCamera = false
    private(set) var capturingPhoto = false
    private(set) var supportsDisplay = false
    private(set) var connected = false
    private(set) var preview: UIImage?
    private(set) var liveFrameReceivedAt: Date?
    private(set) var status = "Connect your Ray-Ban Display glasses"
    var requestingCameraPermission: Bool { permissionRequest != nil || cameraPreparationID != nil }
    var requestingSpeechPermission: Bool { speechPermissionRequest != nil }
    var requestingVoicePermission: Bool { requestingSpeechPermission }
    var errorMessage: String?
    private(set) var navigationNotice: String?
    var onPhoto: ((Data) -> Void)?
    var onCaptureFailed: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onCapture: (() -> Void)?
    var onAction: ((String) -> Void)?
    var onNavigateBoundary: ((Bool) -> Void)?
    var onConnectionLost: (() -> Void)?
    var onStateChange: (() -> Void)?

    @ObservationIgnored private let configurationError: String?
    @ObservationIgnored private var wearables: WearablesInterface?
    @ObservationIgnored private var selector: AutoDeviceSelector?
    @ObservationIgnored private var session: DeviceSession?
    @ObservationIgnored private var camera: MWDATCamera.Camera?
    @ObservationIgnored private var display: Display?
    @ObservationIgnored private var inputs: Inputs?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var inputTokens: [AnyListenerToken] = []
    @ObservationIgnored private var inputID = UUID()
    @ObservationIgnored private var inputAttemptSessionID: UUID?
    @ObservationIgnored private var suspendedInputSessionID: UUID?
    @ObservationIgnored private var inputsActive = false
    @ObservationIgnored private var focusNavigation = GlassesFocusNavigation()
    @ObservationIgnored private var inputSequence = GlassesInputSequence()
    @ObservationIgnored private var acknowledgedAt: ContinuousClock.Instant?
    @ObservationIgnored private var nativeSpeech: GlassesSpeechInput?
    @ObservationIgnored private var displayReady = false
    @ObservationIgnored private var displayFailed = false
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var cameraStopping = false
    @ObservationIgnored private var cameraRequested = false
    @ObservationIgnored private var cameraForeground = true
    @ObservationIgnored private var permissionRequest: UUID?
    @ObservationIgnored private var cameraPreparationID: UUID?
    private var speechPermissionRequest: UUID?
    @ObservationIgnored private var speechPreparationID: UUID?
    @ObservationIgnored private var connectionLossNotified = false
    @ObservationIgnored private var authorizationRecoveryPending = false
    @ObservationIgnored private var authorizationRecoveryAttempted = false
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var cameraID = UUID()
    @ObservationIgnored private var liveFrameAcceptedAfter = Date.distantPast
    @ObservationIgnored private var displayID = UUID()
    @ObservationIgnored private var cardID = UUID()
    @ObservationIgnored private var acknowledgedCardID: UUID?
    @ObservationIgnored private var brandIntroductionSessionID: UUID?
    @ObservationIgnored private var brandIntroductionCardID: UUID?
    @ObservationIgnored private var brandIntroductionFadeStep = 0
    @ObservationIgnored private var showingBrandIntroduction = false
    @ObservationIgnored private var brandIntroductionTask: Task<Void, Never>?
    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var deviceTask: Task<Void, Never>?
    @ObservationIgnored private var connectionDeadline: Task<Void, Never>?
    @ObservationIgnored private var cameraDeadline: Task<Void, Never>?
    @ObservationIgnored private var photoDeadline: Task<Void, Never>?
    @ObservationIgnored private var displayDeadline: Task<Void, Never>?
    @ObservationIgnored private var stopDeadline: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var sendDeadline: Task<Void, Never>?
    @ObservationIgnored private var sessionTokens: [AnyListenerToken] = []
    @ObservationIgnored private var cameraTokens: [AnyListenerToken] = []
    @ObservationIgnored private var displayToken: AnyListenerToken?

    private struct Card {
        var title: String
        var text: String
        var image: UIImage?
        var previous: Bool
        var next: Bool
        var previousLabel = "Back"
        var nextLabel = "Next"
        var capture = false
        var home = false
        var actions: [MendGlassesAction]?
        var items: [MendGlassesAction] = []
        var staticRows: [String] = []
        var preferredActionID: String?
    }
    private struct Transfer {
        let id: UUID
        let view: FlexBox
        let introduction: Bool
    }
    @ObservationIgnored private var currentCard = Card(title: "Start a repair", text: "Look at the problem. Take one clear photo to begin.", previous: false, next: false, home: true)
    @ObservationIgnored private var queuedTransfer: Transfer?
    @ObservationIgnored private var lastRenderedContent: GlassesDisplayContent?

    init(configurationError: String?) {
        self.configurationError = configurationError
        resetCardFocus()
        guard configurationError == nil else {
            errorMessage = configurationError
            status = "Glasses setup needs attention"
            registrationReady = true
            return
        }
        let api = Wearables.shared
        wearables = api
        let selection = AutoDeviceSelector(wearables: api, filter: { $0.supportsDisplay() })
        selector = selection
        registrationTask = Task { [weak self] in
            for await state in api.registrationStateStream() {
                guard !Task.isCancelled, let self else { return }
                self.registrationReady = true
                self.registered = state == .registered
                if state == .available || state == .unavailable {
                    if self.permissionRequest == nil && self.cameraPreparationID == nil && self.speechPreparationID == nil && !self.authorizationRecoveryPending {
                        self.disconnect()
                        self.status = "Register Fixi with Meta AI"
                    }
                }
                self.resumeAfterAuthorizationIfNeeded()
                self.onStateChange?()
            }
        }
        deviceTask = Task { [weak self] in
            for await device in selection.activeDeviceStream() {
                guard !Task.isCancelled, let self else { return }
                self.available = device != nil
                self.resumeAfterAuthorizationIfNeeded()
                self.onStateChange?()
            }
        }
    }

    deinit {
        registrationTask?.cancel(); deviceTask?.cancel()
        connectionDeadline?.cancel(); cameraDeadline?.cancel(); photoDeadline?.cancel()
        displayDeadline?.cancel(); stopDeadline?.cancel(); sendTask?.cancel(); sendDeadline?.cancel()
        brandIntroductionTask?.cancel(); inputTask?.cancel()
        camera?.stop(); display?.stop(); session?.stop()
        let tokens = sessionTokens + cameraTokens + inputTokens + [displayToken].compactMap { $0 }
        Task { for token in tokens { await token.cancel() } }
    }

    func register() async {
        guard wearables != nil else { return }
        errorMessage = nil
        // The ObjC bridge avoids the newer typed-throws protocol ABI on Xcode 16.2.
        do { try await ObjC_Wearables.sharedInstance.startRegistration() }
        catch { errorMessage = error.localizedDescription }
    }

    func handleURL(_ url: URL) async {
        guard wearables != nil else { return }
        do { _ = try await ObjC_Wearables.sharedInstance.handleUrl(url) }
        catch { errorMessage = error.localizedDescription }
    }

    /// Calling Connect again also resumes a camera stopped while reviewing steps.
    func connect(startCamera: Bool = true) {
        guard !stopping else { status = "Finishing the previous connection. Try Connect again shortly."; return }
        guard registered else { errorMessage = "Register Fixi in Meta AI first."; return }
        guard available, let wearables, let selector else {
            errorMessage = "No Ray-Ban Display glasses are available. Check their connection in Meta AI."; return
        }
        errorMessage = nil
        authorizationRecoveryAttempted = false
        if startCamera { cameraRequested = true }
        if session != nil {
            if displayFailed {
                errorMessage = "The display needs a fresh session. Disconnect, then connect again."
            }
            if startCamera { Task { [weak self] in await self?.prepareCamera() } }
            return
        }
        do {
            let next = try wearables.createSession(deviceSelector: selector)
            let id = UUID(); sessionID = id; session = next
            cameraRequested = startCamera
            connectionLossNotified = false
            status = "Connecting to glasses…"
            sessionTokens = [next.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    switch state {
                    case .started:
                        guard !self.stopping else { next.stop(); return }
                        self.connected = true
                        self.connectionLossNotified = false
                        self.connectionDeadline?.cancel()
                        self.status = "Glasses connected"
                        self.supportsDisplay = next.device?.supportsDisplay() == true
                        self.attachDisplay()
                        self.attachInputs()
                        self.onStateChange?()
                        await self.prepareCamera()
                    case .paused:
                        self.connected = false; self.streaming = false; self.clearLiveFrame()
                        self.nativeSpeech?.stop()
                        if self.capturingPhoto {
                            self.failCapture("The glasses paused before the photo arrived. Try taking it again.")
                            self.stopCamera()
                        }
                        self.status = "Glasses paused. Keep them on to resume."
                        self.notifyConnectionLost()
                        self.onStateChange?()
                    case .stopped:
                        let authorizing = self.permissionRequest != nil && self.cameraRequested && !self.stopping
                        self.notifyConnectionLost()
                        self.cleanup(preservingAuthorization: authorizing)
                        self.status = authorizing ? "Waiting for camera authorization to finish…" : "Glasses disconnected"
                    default: break
                    }
                }
            }, next.errorPublisher.listen { [weak self] error in
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    self.errorMessage = error.localizedDescription
                }
            }]
            try next.start()
            connectionDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                guard let self, self.sessionID == id, !self.connected else { return }
                self.errorMessage = "The glasses did not connect. Check Meta AI, then try again."
                self.disconnect()
            }
        } catch {
            errorMessage = error.localizedDescription
            cleanup()
        }
    }

    func disconnect() {
        let hadConnection = session != nil || cameraPreparationID != nil || speechPreparationID != nil || nativeSpeech != nil
        cameraPreparationID = nil
        speechPreparationID = nil
        speechPermissionRequest = nil
        nativeSpeech?.stop()
        if hadConnection { notifyConnectionLost() }
        guard session != nil else {
            stopCamera()
            status = "Glasses disconnected"
            return
        }
        stopping = true; connected = false
        onStateChange?()
        authorizationRecoveryPending = false
        if capturingPhoto { failCapture("The glasses disconnected before the photo arrived.") }
        cameraRequested = false; permissionRequest = nil
        connectionDeadline?.cancel()
        stopCamera()
        invalidateDisplay()
        display?.stop()
        session?.stop()
        status = "Disconnecting glasses…"
        let id = sessionID
        stopDeadline?.cancel()
        stopDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.sessionID == id, self.stopping else { return }
            self.cleanup()
            self.status = "Glasses disconnected"
        }
    }

    /// Resolve the external camera authorization before a speech capability exists.
    /// Meta AI can pause the shared device session during authorization; doing this
    /// first avoids silently retiring an already listening microphone. The caller
    /// may continue without visual context on failure. No camera stream is opened.
    func prepareConversationCamera() async throws {
        try Task.checkCancellation()
        guard configurationError == nil, wearables != nil else {
            throw VoicePreparationError(configurationError ?? "Glasses access is unavailable.")
        }
        guard cameraPreparationID == nil, speechPreparationID == nil else {
            throw VoicePreparationError("Glasses authorization is already starting.")
        }
        guard !capturingPhoto else {
            throw VoicePreparationError("Finish the current photo before starting conversation.")
        }
        let request = UUID()
        cameraPreparationID = request
        defer {
            if cameraPreparationID == request { cameraPreparationID = nil; onStateChange?() }
        }
        let registrationDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !registrationReady, ContinuousClock.now < registrationDeadline {
            try checkCameraPreparation(request)
            try await Task.sleep(for: .milliseconds(100))
        }
        try checkCameraPreparation(request)
        guard registrationReady, registered else {
            throw VoicePreparationError("Register Fixi through Meta AI before using its camera.")
        }
        try await stopCameraAndWait()
        try checkCameraPreparation(request)
        status = "Checking the glasses camera…"
        onStateChange?()
        var permission: ObjC_PermissionStatus?
        var authorizationFailure: Error?
        do {
            permission = try await boundedPermission(timeout: .seconds(8), timeoutMessage: "Camera authorization timed out. Return from Meta AI and try again.") {
                try await ObjC_Wearables.sharedInstance.checkPermissionStatus(.camera)
            }
            try checkCameraPreparation(request)
            if permission != .granted {
                status = "Allow Fixi camera access in Meta AI"
                onStateChange?()
                permission = try await boundedPermission(timeout: .seconds(90), timeoutMessage: "Camera authorization timed out. Return from Meta AI and try again.") {
                    try await ObjC_Wearables.sharedInstance.requestPermission(.camera)
                }
            }
        } catch {
            try checkCameraPreparation(request)
            if error is CancellationError { throw error }
            authorizationFailure = error
        }
        try checkCameraPreparation(request)
        // Keep the handoff flag until foreground even after denial, so the
        // following microphone request cannot start behind the external sheet.
        let foregroundDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while UIApplication.shared.applicationState != .active, ContinuousClock.now < foregroundDeadline {
            try checkCameraPreparation(request)
            try await Task.sleep(for: .milliseconds(100))
        }
        try checkCameraPreparation(request)
        guard UIApplication.shared.applicationState == .active else {
            throw CancellationError()
        }
        if let authorizationFailure { throw authorizationFailure }
        guard permission == .granted else {
            throw VoicePreparationError("Camera access was not granted. I can still listen, but I cannot see your project.")
        }
        status = "Camera access ready"
    }

    private func checkCameraPreparation(_ id: UUID) throws {
        try Task.checkCancellation()
        guard cameraPreparationID == id else { throw CancellationError() }
    }

    /// Uses native DAT transcription. Starting conversation never opens a camera
    /// stream or a Bluetooth hands-free route; those interfere with speaker output.
    func makeSpeechInput() async throws -> any SceneVoiceSpeechInput {
        try Task.checkCancellation()
        guard configurationError == nil, wearables != nil else {
            throw VoicePreparationError(configurationError ?? "Glasses access is unavailable.")
        }
        guard speechPreparationID == nil, cameraPreparationID == nil else {
            throw VoicePreparationError("A conversation is already starting.")
        }
        guard !capturingPhoto else {
            throw VoicePreparationError("Finish the current photo before starting conversation.")
        }
        let request = UUID()
        speechPreparationID = request
        defer {
            if speechPreparationID == request { speechPreparationID = nil }
            if speechPermissionRequest == request { speechPermissionRequest = nil }
        }
        let registrationDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !registrationReady, ContinuousClock.now < registrationDeadline {
            try checkSpeechPreparation(request)
            try await Task.sleep(for: .milliseconds(100))
        }
        try checkSpeechPreparation(request)
        guard registrationReady, registered else {
            throw VoicePreparationError("Register Fixi through Meta AI, then try voice chat again.")
        }
        try await stopCameraAndWait()
        try checkSpeechPreparation(request)
        var permission = try await boundedPermission(timeout: .seconds(8)) {
            try await ObjC_Wearables.sharedInstance.checkPermissionStatus(.microphone)
        }
        try checkSpeechPreparation(request)
        if permission != .granted {
            speechPermissionRequest = request
            status = "Allow Fixi microphone access in Meta AI"
            permission = try await boundedPermission(timeout: .seconds(90)) {
                try await ObjC_Wearables.sharedInstance.requestPermission(.microphone)
            }
            try checkSpeechPreparation(request)
            guard permission == .granted else {
                throw VoicePreparationError("Allow the glasses microphone in Meta AI, then try voice chat again.")
            }
            let foregroundDeadline = ContinuousClock.now.advanced(by: .seconds(30))
            while UIApplication.shared.applicationState != .active, ContinuousClock.now < foregroundDeadline {
                try checkSpeechPreparation(request)
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        try checkSpeechPreparation(request)
        guard UIApplication.shared.applicationState == .active else {
            throw VoicePreparationError("Return to Fixi to start voice chat.")
        }
        errorMessage = nil
        let sessionDeadline = ContinuousClock.now.advanced(by: .seconds(25))
        while ContinuousClock.now < sessionDeadline {
            try checkSpeechPreparation(request)
            if connected, session?.state == .started, !stopping { break }
            if registered, available, session == nil, !stopping { connect(startCamera: false) }
            if let errorMessage { throw VoicePreparationError(errorMessage) }
            try await Task.sleep(for: .milliseconds(100))
        }
        try checkSpeechPreparation(request)
        guard connected, let session, session.state == .started, !stopping else {
            throw VoicePreparationError("Wear and reconnect the glasses, then try voice chat again.")
        }
        // A camera permission result queued before this request cannot restart it.
        try await stopCameraAndWait()
        try checkSpeechPreparation(request)
        guard connected, session === self.session, session.state == .started, !stopping else {
            throw VoicePreparationError("The glasses session changed. Try voice chat again.")
        }
        if let nativeSpeech { return nativeSpeech }
        let input = GlassesSpeechInput(session: session)
        nativeSpeech = input
        status = "Glasses ready for voice chat"
        return input
    }

    private func checkSpeechPreparation(_ id: UUID) throws {
        try Task.checkCancellation()
        guard speechPreparationID == id else { throw CancellationError() }
    }

    private struct VoicePreparationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// The SDK authorization sheet is external to the app. A late result cannot
    /// keep a cancelled start alive or resume a newer conversation request.
    @MainActor private final class PermissionWait {
        var continuation: CheckedContinuation<ObjC_PermissionStatus, Error>?
        var operation: Task<Void, Never>?
        var timeout: Task<Void, Never>?
        func finish(_ result: Result<ObjC_PermissionStatus, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            operation?.cancel(); operation = nil
            timeout?.cancel(); timeout = nil
            continuation.resume(with: result)
        }
    }

    private func boundedPermission(timeout: Duration,
                                   timeoutMessage: String = "Microphone authorization timed out. Return from Meta AI and try voice chat again.",
                                   operation: @escaping @MainActor () async throws -> ObjC_PermissionStatus) async throws -> ObjC_PermissionStatus {
        let wait = PermissionWait()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                wait.continuation = continuation
                wait.operation = Task { @MainActor in
                    do { wait.finish(.success(try await operation())) }
                    catch { wait.finish(.failure(error)) }
                }
                wait.timeout = Task { @MainActor in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    wait.finish(.failure(VoicePreparationError(timeoutMessage)))
                }
            }
        }, onCancel: {
            Task { @MainActor in wait.finish(.failure(CancellationError())) }
        })
    }

    private func prepareCamera() async {
        guard cameraForeground, connected, !stopping, cameraRequested, camera == nil, permissionRequest == nil, cameraPreparationID == nil else { return }
        let request = UUID()
        permissionRequest = request
        defer {
            if permissionRequest == request {
                permissionRequest = nil
                resumeAfterAuthorizationIfNeeded()
            }
        }
        do {
            var permission = try await ObjC_Wearables.sharedInstance.checkPermissionStatus(.camera)
            guard cameraRequested, permissionRequest == request, !stopping else { return }
            if permission != .granted {
                guard cameraForeground else { return }
                guard !authorizationRecoveryAttempted else {
                    cameraRequested = false; authorizationRecoveryPending = false
                    errorMessage = "Camera authorization did not persist. Connect again to request access."
                    return
                }
                status = "Allow Fixi camera access in Meta AI"
                permission = try await ObjC_Wearables.sharedInstance.requestPermission(.camera)
            }
            guard cameraRequested, permissionRequest == request, !stopping else { return }
            guard permission == .granted else {
                cameraRequested = false; authorizationRecoveryPending = false
                errorMessage = "Camera access was not granted. Connect again to request it."
                return
            }
            // Authorization can temporarily pause the shared device session.
            if connected { authorizationRecoveryPending = false; attachCamera() }
            else {
                authorizationRecoveryPending = session == nil
                status = "Access granted. Waiting for the glasses to resume."
            }
        } catch {
            guard permissionRequest == request else { return }
            authorizationRecoveryPending = false
            errorMessage = error.localizedDescription
        }
    }

    private func resumeAfterAuthorizationIfNeeded() {
        guard cameraForeground, authorizationRecoveryPending, permissionRequest == nil, cameraRequested,
              !stopping, registered, available, session == nil, !authorizationRecoveryAttempted else { return }
        authorizationRecoveryPending = false
        connect()
        authorizationRecoveryAttempted = true
    }

    private func attachCamera() {
        guard cameraForeground, let session, connected, !stopping, cameraRequested, camera == nil else { return }
        do {
            clearLiveFrame()
            let config = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 7)
            guard let next = try session.addCamera(config: config) else {
                errorMessage = "The glasses camera is unavailable. Reconnect to try again."; return
            }
            camera = next; startingCamera = true; cameraStopping = false
            status = "Starting camera…"
            let id = UUID(); cameraID = id
            cameraTokens = [next.stream.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    guard let self, self.cameraID == id else { return }
                    if state != .streaming || !self.streaming { self.clearLiveFrame() }
                    self.streaming = state == .streaming && !self.cameraStopping
                    if state == .streaming && !self.cameraStopping {
                        self.startingCamera = false; self.cameraDeadline?.cancel()
                        self.status = "Camera ready"
                        if self.currentCard.home { self.renderCurrentCard() }
                    } else if state == .paused {
                        self.clearLiveFrame()
                        if self.capturingPhoto {
                            self.failCapture("The camera paused before the photo arrived. Try taking it again.")
                            self.stopCamera()
                        }
                        self.status = "Camera paused"
                    } else if state == .stopped {
                        if self.capturingPhoto { self.failCapture("The camera stopped before the photo arrived.") }
                        let resumeRequested = self.cameraStopping && self.cameraRequested
                        self.releaseCamera()
                        if !self.stopping { self.status = "Camera stopped" }
                        if resumeRequested && self.connected {
                            Task { [weak self] in await self?.prepareCamera() }
                        } else {
                            self.cameraRequested = false
                        }
                    }
                }
            }, next.stream.videoFramePublisher.listen { [weak self] frame in
                let receivedAt = Date()
                Task { @MainActor in
                    guard let self, self.cameraForeground, self.cameraID == id, self.streaming, !self.cameraStopping,
                          receivedAt >= self.liveFrameAcceptedAfter else { return }
                    guard let image = frame.makeUIImage() else { self.clearLiveFrame(); return }
                    self.preview = image
                    self.liveFrameReceivedAt = receivedAt
                }
            }, next.stream.photoDataPublisher.listen { [weak self] photo in
                Task { @MainActor in
                    guard let self, self.cameraID == id, self.capturingPhoto, !self.cameraStopping else { return }
                    guard let image = UIImage(data: photo.data), let jpeg = Self.normalizedJPEG(image) else {
                        self.failCapture("The photo could not be decoded. Take another photo."); return
                    }
                    self.cancelPhoto()
                    self.onPhoto?(jpeg)
                }
            }, next.stream.errorPublisher.listen { [weak self] error in
                Task { @MainActor in
                    guard let self, self.cameraID == id else { return }
                    if self.capturingPhoto { self.failCapture(error.localizedDescription) }
                    else { self.errorMessage = error.localizedDescription }
                    self.stopCamera()
                }
            }]
            next.stream.start()
            cameraDeadline?.cancel()
            cameraDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                guard let self, self.cameraID == id, self.startingCamera else { return }
                self.errorMessage = "The camera did not start. Connect again to retry."
                self.stopCamera()
            }
        } catch { errorMessage = error.localizedDescription; startingCamera = false }
    }

    func capturePhoto() {
        guard streaming, !cameraStopping, let camera else {
            failCapture("Connect the glasses camera before taking a photo."); return
        }
        guard !capturingPhoto else { return }
        errorMessage = nil; capturingPhoto = true
        guard camera.stream.capturePhoto(format: .jpeg) else {
            failCapture("The shutter is busy. Try again."); return
        }
        let id = cameraID
        photoDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.cameraID == id, self.capturingPhoto else { return }
            // Retire this camera generation so a delayed old JPEG cannot satisfy a new shutter.
            self.failCapture("The photo did not arrive. Connect the camera again before retrying.")
            self.stopCamera()
        }
    }

    /// External permission sheets can background the phone while authorization
    /// is pending. Preserve that request, but never attach a camera while away.
    func setCameraForeground(_ active: Bool) {
        cameraForeground = active
        if !active {
            if let inputs {
                let mayResume = inputs.state == .active || inputs.state == .activating
                releaseInputs()
                // Retire the stream before iOS can suspend its consumer. Old
                // buffered gestures must never resume against a newer card.
                suspendedInputSessionID = mayResume ? sessionID : nil
            }
            clearLiveFrame()
            if camera != nil || streaming || startingCamera { stopCamera() }
        } else {
            if suspendedInputSessionID == sessionID { attachInputs() }
            if cameraRequested {
                resumeAfterAuthorizationIfNeeded()
                Task { [weak self] in await self?.prepareCamera() }
            }
        }
    }

    func stopCamera() {
        if capturingPhoto { failCapture("Photo capture was interrupted. Try taking the photo again.") }
        authorizationRecoveryPending = false
        cameraRequested = false; permissionRequest = nil
        streaming = false; startingCamera = false; clearLiveFrame()
        cancelPhoto(); cameraDeadline?.cancel()
        guard let camera else { return }
        cameraStopping = true
        camera.stop()
        let id = cameraID
        cameraDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.cameraID == id, self.cameraStopping else { return }
            // Do not create another camera while an old capability may still be active.
            self.errorMessage = "The camera did not stop cleanly. Reconnect the glasses."
            self.disconnect()
        }
    }

    /// Camera shutdown is asynchronous on glasses. Wait for the capability to
    /// release its audio route before synthesizing a reply through the speakers.
    func stopCameraAndWait() async throws {
        try Task.checkCancellation()
        let id = sessionID
        stopCamera()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while camera != nil {
            try Task.checkCancellation()
            guard sessionID == id, !stopping else {
                throw VoicePreparationError("The glasses disconnected while closing the camera.")
            }
            guard ContinuousClock.now < deadline else {
                throw VoicePreparationError("The camera could not close for voice chat. Reconnect the glasses and try again.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard !stopping else { throw VoicePreparationError("The glasses are disconnecting.") }
    }

    private func cancelPhoto() {
        capturingPhoto = false
        photoDeadline?.cancel(); photoDeadline = nil
    }

    /// Cancel intentionally without surfacing an error. Retiring the camera excludes delayed JPEGs.
    func cancelCapture() {
        guard capturingPhoto else { return }
        cancelPhoto()
        stopCamera()
    }

    private func failCapture(_ message: String) {
        cancelPhoto()
        errorMessage = message
        onCaptureFailed?(message)
    }

    private func releaseCamera() {
        cameraID = UUID()
        cancelPhoto(); cameraDeadline?.cancel(); cameraDeadline = nil
        let tokens = cameraTokens; cameraTokens.removeAll()
        Task { for token in tokens { await token.cancel() } }
        camera = nil; cameraStopping = false; streaming = false; startingCamera = false; clearLiveFrame()
    }

    /// Copy only a recent frame when a question needs visual context. Streaming
    /// retains one decoded image, and does not encode or save every frame.
    func livePhoto(maxAge: TimeInterval = 2) -> MendPhoto? {
        guard maxAge.isFinite, maxAge >= 0, cameraForeground, connected, streaming, !cameraStopping,
              let receivedAt = liveFrameReceivedAt, let preview else { return nil }
        let age = Date().timeIntervalSince(receivedAt)
        guard age >= 0, age <= maxAge,
              let jpeg = Self.normalizedJPEG(preview),
              let photo = try? MendPhoto.make(data: jpeg, source: "Glasses live view") else { return nil }
        return MendPhoto(id: photo.id, jpeg: photo.jpeg, image: photo.image,
                         source: photo.source, capturedAt: receivedAt)
    }

    private func clearLiveFrame() {
        liveFrameAcceptedAfter = Date()
        preview = nil
        liveFrameReceivedAt = nil
    }

    private func attachInputs() {
        // Let DAT perform selection and scrolling on the glasses. Consuming
        // these gestures and re-sending a view for each move caused focus jumps.
        // Keep the optional path dormant until it has a validated focus API.
        guard GlassesNavigationPolicy.usesRawInputs else {
            suspendedInputSessionID = nil
            if inputs != nil { releaseInputs() }
            navigationNotice = nil
            return
        }
        guard let session, session.state == .started, connected, supportsDisplay, display != nil, !displayFailed, !stopping,
              cameraForeground, inputs == nil,
              inputAttemptSessionID != sessionID || suspendedInputSessionID == sessionID else { return }
        // Inputs is an optional development/beta capability. Only a previously
        // attached stream may resume in this session; terminal failures wait
        // for a new session and never interrupt camera/voice.
        inputAttemptSessionID = sessionID
        suspendedInputSessionID = nil
        navigationNotice = nil
        let generation = UUID(), expectedSession = sessionID
        inputID = generation
        inputSequence = GlassesInputSequence()
        do {
            guard let next = try session.addInputs(configuration: InputsConfiguration(
                sources: [.captouch, .neuralBand], consumeBack: false
            )) else {
                failInputs("Swipe navigation is unavailable. Use the buttons or your voice.")
                return
            }
            inputs = next
            inputTokens = [
                next.statePublisher.listen { [weak self] state in
                    Task { @MainActor in
                        guard let self, self.inputID == generation, self.sessionID == expectedSession else { return }
                        let active = state == .active
                        guard self.inputsActive != active else { return }
                        self.inputsActive = active
                        // This is an adapter-only redraw: keep the current
                        // app-owned focus when Inputs activates or pauses.
                        self.renderCurrentCard()
                    }
                },
                next.errorPublisher.listen { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.inputID == generation, self.sessionID == expectedSession else { return }
                        let notice = error == .permissionDenied
                            ? "Swipe navigation needs Meta Inputs access. Use the buttons or your voice."
                            : "Swipe navigation is unavailable. Use the buttons or your voice."
                        self.failInputs(notice)
                    }
                }
            ]
            inputsActive = next.state == .active
            let events = next.events
            // Drain independently of display sends. Capture host receive time
            // before hopping to MainActor, so input queued before a card's ACK
            // cannot operate on that newly acknowledged card.
            inputTask = Task.detached { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    let receivedAt = ContinuousClock.now
                    Task { @MainActor [weak self] in
                        guard let self, self.inputID == generation, self.sessionID == expectedSession else { return }
                        self.receiveInput(event, receivedAt: receivedAt)
                    }
                }
                guard !Task.isCancelled else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.inputID == generation, self.sessionID == expectedSession else { return }
                    self.failInputs("Swipe navigation stopped. Use the buttons or your voice.")
                }
            }
            if inputsActive { renderCurrentCard() }
        } catch {
            failInputs("Swipe navigation is unavailable. Use the buttons or your voice.")
        }
    }

    private func receiveInput(_ event: InputEvent, receivedAt: ContinuousClock.Instant) {
        guard inputSequence.observe(event.timestampMs), inputsActive, connected,
              cameraForeground, UIApplication.shared.applicationState == .active,
              let acknowledgedAt, receivedAt >= acknowledgedAt,
              acceptsAction(cardID, allowDuringCapture: true) else { return }
        switch event {
        case .nav(let direction, _, _):
            let move: GlassesFocusNavigation.Direction
            switch direction {
            case .left: move = .left
            case .right: move = .right
            case .up: move = .up
            case .down: move = .down
            }
            switch focusNavigation.move(move) {
            case .focused:
                renderCurrentCard()
            case .boundary(let forward):
                performInputTransition { self.onNavigateBoundary?(forward) }
            case .unchanged: break
            }
        case .select:
            guard let actionID = focusNavigation.focusedID else { return }
            let selectedCardID = cardID
            // Selection validation must run before invalidating the ACK.
            guard enabledActionIDs.contains(actionID) else { return }
            performInputTransition { self.dispatchAction(actionID, expectedCardID: selectedCardID) }
        case .back:
            // consumeBack is false and real hardware currently does not emit
            // this event. Retain behavior for supported future/mock devices.
            performInputTransition { self.onNavigateBoundary?(false) }
        case .button, .capture, .drag:
            break // These sources are deliberately not captured by this app.
        @unknown default:
            break
        }
    }

    private func performInputTransition(_ action: () -> Void) {
        let previousCardID = cardID
        acknowledgedCardID = nil
        acknowledgedAt = nil
        action()
        // An unavailable edge action may intentionally leave the model alone.
        // A fresh ACK prevents double selection without trapping the controls.
        if cardID == previousCardID { renderCurrentCard(force: true) }
    }

    private func failInputs(_ notice: String) {
        suspendedInputSessionID = nil
        releaseInputs()
        navigationNotice = notice
        if displayReady, !stopping { renderCurrentCard() }
    }

    private func releaseInputs() {
        inputID = UUID()
        inputsActive = false
        inputTask?.cancel(); inputTask = nil
        let tokens = inputTokens; inputTokens.removeAll()
        Task { for token in tokens { await token.cancel() } }
        if inputs != nil { try? session?.removeInputs() }
        inputs = nil
        inputSequence = GlassesInputSequence()
    }

    private func footerActions(for card: Card) -> [MendGlassesAction] {
        if let actions = card.actions { return actions.filter(\.enabled) }
        if card.home {
            return [MendGlassesAction(id: "__home", label: streaming ? "Take photo" : "Start camera")]
        }
        var actions: [MendGlassesAction] = []
        if card.previous { actions.append(MendGlassesAction(id: "__previous", label: card.previousLabel)) }
        if card.next { actions.append(MendGlassesAction(id: "__next", label: card.nextLabel)) }
        if card.capture { actions.append(MendGlassesAction(id: "__capture", label: "Update photo")) }
        return actions
    }

    private var enabledActionIDs: [String] {
        currentCard.items.filter(\.enabled).map(\.id) + footerActions(for: currentCard).map(\.id)
    }

    private func resetCardFocus() {
        focusNavigation.reset(itemIDs: currentCard.items.filter(\.enabled).map(\.id),
                              footerIDs: footerActions(for: currentCard).map(\.id),
                              preferredID: currentCard.preferredActionID)
    }

    private func attachDisplay() {
        guard let session, connected, supportsDisplay, display == nil, !displayFailed, !stopping else { return }
        do {
            let next = try session.addDisplay()
            display = next
            let id = UUID(); displayID = id
            displayToken = next.statePublisher.listen { [weak self] state in
                Task { @MainActor in
                    guard let self, self.displayID == id else { return }
                    if state == .started && !self.stopping {
                        if !self.displayReady, self.brandIntroductionSessionID != self.sessionID {
                            self.brandIntroductionSessionID = self.sessionID
                            self.showingBrandIntroduction = true
                        }
                        self.displayReady = true; self.displayDeadline?.cancel()
                        self.renderCurrentCard()
                    } else if state == .stopped {
                        self.invalidateDisplay()
                        self.displayFailed = true
                        self.display = nil
                        if !self.stopping { self.errorMessage = "The glasses display stopped. Your instructions remain on iPhone." }
                    }
                }
            }
            next.start()
            displayDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.displayID == id, !self.displayReady else { return }
                self.failDisplay("The glasses display did not become ready. Reconnect to retry.")
            }
        } catch { displayFailed = true; errorMessage = error.localizedDescription }
    }

    func showCard(title: String, text: String, image: UIImage?, previous: Bool, next: Bool,
                  nextLabel: String = "Next", previousLabel: String = "Back", capture: Bool = false,
                  actions: [MendGlassesAction]? = nil, items: [MendGlassesAction] = [],
                  staticRows: [String] = [], preferredActionID: String? = nil) {
        let nextCard = Card(title: title, text: text, image: image, previous: previous,
                           next: next, previousLabel: previousLabel, nextLabel: nextLabel, capture: capture,
                           actions: actions.map { Array($0.filter(\.enabled).prefix(3)) }, items: items.filter(\.enabled),
                           staticRows: staticRows, preferredActionID: preferredActionID)
        guard displayContent(for: nextCard) != displayContent(for: currentCard) else { return }
        currentCard = nextCard
        resetCardFocus()
        renderCurrentCard()
    }

    func showHome() {
        currentCard = Card(title: "Start a repair", text: "Look at the problem. Take one clear photo to begin.", previous: false, next: false, home: true)
        resetCardFocus()
        renderCurrentCard()
    }

    private func preferredActionID(for card: Card) -> String? {
        if inputsActive { return focusNavigation.focusedID }
        return GlassesNavigationPolicy.preferredFooterID(
            itemIDs: card.items.map(\.id), footerIDs: footerActions(for: card).map(\.id),
            preferredID: card.preferredActionID
        )
    }

    private func displayContent(for card: Card) -> GlassesDisplayContent {
        GlassesDisplayContent(
            title: card.title, text: card.text, imageIdentity: card.image.map { ObjectIdentifier($0) },
            items: card.items.map { .init(id: $0.id, label: $0.label) },
            footer: footerActions(for: card).map { .init(id: $0.id, label: $0.label) },
            staticRows: card.staticRows, usesCustomActions: card.actions != nil,
            usesRawInputs: inputsActive, preferredActionID: preferredActionID(for: card)
        )
    }

    private func renderCurrentCard(force: Bool = false) {
        if showingBrandIntroduction, !cameraForeground {
            // Backgrounding must publish the passive card immediately rather
            // than leave a logo frozen while iOS suspends its fade timer.
            brandIntroductionTask?.cancel(); brandIntroductionTask = nil
            showingBrandIntroduction = false; brandIntroductionCardID = nil
            brandIntroductionFadeStep = 0
        }
        // Keep accepting new model cards while the noninteractive introduction
        // holds and fades, then send the latest card once the introduction ends.
        if showingBrandIntroduction {
            if brandIntroductionCardID == nil { renderBrandIntroduction(fadeStep: 0) }
            return
        }
        let content = displayContent(for: currentCard)
        guard force || content != lastRenderedContent else { return }
        // Invalidate actions only when the view actually changes. Sending the
        // same Menu again discards the focus/scroll position held on glasses.
        let id = UUID(); cardID = id; acknowledgedCardID = nil; acknowledgedAt = nil
        guard displayReady else { return }
        lastRenderedContent = content
        let card = currentCard
        let actions = footerActions(for: card)
        let preferredActionID = self.preferredActionID(for: card)
        let view = FlexBox(direction: .column, spacing: 8, crossAlignment: .stretch) {
            FlexBox(direction: .column, spacing: 8, crossAlignment: .stretch) {
                if !card.title.isEmpty { Text(card.title, style: .heading).flexShrink(0) }
                if let image = card.image {
                    Image(image: Self.displayImage(image), sizePreset: .fill, cornerRadius: .small).flexGrow(1).flexShrink(1)
                }
                if !card.text.isEmpty { Text(card.text, style: .body).flexShrink(0) }
                // Left-aligned tappable rows keep native scrolling/selection.
                // Button labels are centered and cannot be text-aligned in DAT.
                for item in card.items {
                    if inputsActive {
                        nativeChecklistButton(item, cardID: id, preferred: item.id == preferredActionID)
                            .flexShrink(0)
                    } else {
                        nativeItem(item, cardID: id).flexShrink(0)
                    }
                }
                // Parts use the same list rhythm as steps, without creating
                // focus targets or implying that a purchase opens on glasses.
                for row in card.staticRows {
                    nativeStaticRow(row).flexShrink(0)
                }
            }.flexGrow(1).flexShrink(0)
            if !actions.isEmpty {
                ButtonGroup(alignment: .start) {
                    for action in actions {
                        nativeButton(action, cardID: id, primary: card.items.isEmpty && action.id == actions.first?.id,
                                     preferred: action.id == preferredActionID)
                    }
                }.flexShrink(0)
            }
        }.padding(16)
        queuedTransfer = Transfer(id: id, view: view, introduction: false)
        startSendWorker()
    }

    private func renderBrandIntroduction(fadeStep: Int) {
        guard showingBrandIntroduction, displayReady, !stopping else { return }
        let id = UUID(); cardID = id; acknowledgedCardID = nil; acknowledgedAt = nil
        brandIntroductionCardID = id; brandIntroductionFadeStep = fadeStep
        let image = Self.brandIntroductionImage(opacity: 1 - CGFloat(fadeStep) / 2)
        let view = FlexBox(direction: .column, alignment: .center, crossAlignment: .center) {
            Image(image: image, sizePreset: .fill, cornerRadius: .none).flexGrow(1).flexShrink(1)
        }.padding(16)
        queuedTransfer = Transfer(id: id, view: view, introduction: true)
        startSendWorker()
    }

    private func finishBrandIntroductionAfterDisplayAcknowledges(_ id: UUID) {
        guard showingBrandIntroduction, brandIntroductionCardID == id, brandIntroductionTask == nil else { return }
        let generation = displayID, session = sessionID
        let fadeStep = brandIntroductionFadeStep
        brandIntroductionTask = Task { [weak self] in
            // DAT 1.0.1 has no native opacity animation. Fade the bubble in
            // two transparent image frames, never overlapping sends.
            // Slow transport can extend the fade, but cannot skip the initial hold.
            do { try await Task.sleep(for: .milliseconds(fadeStep == 0 ? 500 : 50)) } catch { return }
            guard let self, self.displayID == generation, self.sessionID == session,
                  self.displayReady, !self.stopping, self.brandIntroductionCardID == id else { return }
            self.brandIntroductionTask = nil
            if fadeStep < 2 {
                self.renderBrandIntroduction(fadeStep: fadeStep + 1)
                return
            }
            self.showingBrandIntroduction = false; self.brandIntroductionCardID = nil
            self.brandIntroductionFadeStep = 0
            self.renderCurrentCard()
        }
    }

    private func nativeButton(_ action: MendGlassesAction, cardID: UUID, primary: Bool, preferred: Bool) -> Button {
        let button = Button(label: action.label, style: primary ? .primary : .secondary, onClick: { [weak self] in
            Task { @MainActor in
                self?.dispatchSelection(action.id, cardID: cardID)
            }
        })
        return preferred ? button.actionRole(.primary) : button
    }

    private func nativeChecklistButton(_ item: MendGlassesAction, cardID: UUID, preferred: Bool) -> Button {
        let button = Button(label: item.label, style: .secondary, onClick: { [weak self] in
            Task { @MainActor in self?.dispatchSelection(item.id, cardID: cardID) }
        }).alignSelf(.stretch)
        return preferred ? button.actionRole(.primary) : button
    }

    private func nativeItem(_ item: MendGlassesAction, cardID: UUID) -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            Text(item.label, style: .body).flexGrow(1).flexShrink(1)
            Icon(name: .arrowRight, style: .outline).flexShrink(0)
        }.padding(12).background(.card).onTap { [weak self] in
            Task { @MainActor in self?.dispatchSelection(item.id, cardID: cardID) }
        }
    }

    private func nativeStaticRow(_ label: String) -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            Text("○", style: .body).flexShrink(0)
            Text(label, style: .body).flexGrow(1).flexShrink(1)
        }.padding(12).background(.card)
    }

    private func dispatchSelection(_ actionID: String, cardID: UUID) {
        // Inputs consumes these surfaces. Never also execute a native callback
        // for the same pinch, including callbacks queued just before activation.
        guard !inputsActive, acceptsAction(cardID, allowDuringCapture: true),
              enabledActionIDs.contains(actionID) else { return }
        performInputTransition { self.dispatchAction(actionID, expectedCardID: cardID) }
    }

    private func dispatchAction(_ actionID: String, expectedCardID: UUID) {
        guard cardID == expectedCardID, enabledActionIDs.contains(actionID) else { return }
        if currentCard.actions == nil {
            switch actionID {
            case "__home":
                if streaming { captureAction() } else { connect() }
            case "__previous": onPrevious?()
            case "__next": onNext?()
            case "__capture": captureAction()
            default: onAction?(actionID)
            }
        } else { onAction?(actionID) }
    }

    private func acceptsAction(_ id: UUID, allowDuringCapture: Bool = false) -> Bool {
        connected && cameraForeground && UIApplication.shared.applicationState == .active &&
        displayReady && !showingBrandIntroduction && !stopping && (allowDuringCapture || !capturingPhoto) && acknowledgedCardID == id && cardID == id
    }

    private func captureAction() {
        if let onCapture { onCapture() } else { capturePhoto() }
    }

    /// Only one send runs per display. Intermediate steps coalesce into the latest intent.
    private func startSendWorker() {
        guard sendTask == nil, let display, displayReady else { return }
        let id = displayID
        sendTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.displayID == id, let transfer = self.queuedTransfer {
                self.queuedTransfer = nil
                self.sendDeadline?.cancel()
                self.sendDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let self, self.displayID == id else { return }
                    self.failDisplay("The glasses did not acknowledge this card. Reconnect the display; continue on iPhone.")
                }
                do {
                    try await display.send(transfer.view)
                    guard !Task.isCancelled, self.displayID == id else { break }
                    self.sendDeadline?.cancel()
                    if self.cardID == transfer.id {
                        self.acknowledgedCardID = transfer.id
                        self.acknowledgedAt = ContinuousClock.now
                    }
                    if transfer.introduction { self.finishBrandIntroductionAfterDisplayAcknowledges(transfer.id) }
                } catch {
                    guard !Task.isCancelled, self.displayID == id else { break }
                    self.sendDeadline?.cancel()
                    if self.queuedTransfer == nil {
                        self.failDisplay("Could not show the card on glasses: \(error.localizedDescription)")
                        break
                    }
                }
            }
            guard let self, self.displayID == id else { return }
            self.sendTask = nil
        }
    }

    private func failDisplay(_ message: String) {
        errorMessage = message
        displayFailed = true
        invalidateDisplay()
        display?.stop()
    }

    private func invalidateDisplay() {
        suspendedInputSessionID = nil
        releaseInputs()
        displayID = UUID(); displayReady = false; acknowledgedCardID = nil; acknowledgedAt = nil
        lastRenderedContent = nil
        brandIntroductionTask?.cancel(); brandIntroductionTask = nil
        showingBrandIntroduction = false; brandIntroductionCardID = nil
        brandIntroductionFadeStep = 0
        queuedTransfer = nil
        sendTask?.cancel(); sendTask = nil
        sendDeadline?.cancel(); sendDeadline = nil
        displayDeadline?.cancel(); displayDeadline = nil
        if let token = displayToken { Task { await token.cancel() } }
        displayToken = nil
    }

    private func cleanup(preservingAuthorization: Bool = false) {
        if capturingPhoto { failCapture("The glasses disconnected before the photo arrived.") }
        let preservedRequest = preservingAuthorization ? permissionRequest : nil
        let attemptedRecovery = authorizationRecoveryAttempted
        sessionID = UUID(); connected = false; stopping = false
        cameraRequested = false; permissionRequest = nil
        connectionDeadline?.cancel(); stopDeadline?.cancel()
        nativeSpeech?.stop(); nativeSpeech = nil
        releaseCamera(); invalidateDisplay()
        let tokens = sessionTokens; sessionTokens.removeAll()
        Task { for token in tokens { await token.cancel() } }
        session = nil; display = nil; supportsDisplay = false; displayFailed = false
        permissionRequest = preservedRequest
        cameraRequested = preservedRequest != nil
        authorizationRecoveryPending = preservedRequest != nil
        authorizationRecoveryAttempted = preservingAuthorization && attemptedRecovery
        onStateChange?()
    }

    private func notifyConnectionLost() {
        // Initial authorization owns transparent session recovery, before an
        // active microphone exists. Later session loss must end the conversation
        // instead of displaying a stopped microphone as listening.
        guard cameraPreparationID == nil, speechPreparationID == nil, !connectionLossNotified else { return }
        connectionLossNotified = true
        onConnectionLost?()
    }

    private static func normalizedJPEG(_ image: UIImage) -> Data? {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > 0 else { return nil }
        let factor = min(1, 1600 / longEdge)
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.9)
    }

    private static func displayImage(_ image: UIImage) -> UIImage {
        // Fit preserves arrows/circles at the edges; do not crop the annotated photo.
        let size = CGSize(width: 560, height: 260)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: size))
            guard image.size.width > 0, image.size.height > 0 else { return }
            let scale = min(size.width / image.size.width, size.height / image.size.height)
            let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                                  width: fitted.width, height: fitted.height))
        }
    }

    private static func brandIntroductionImage(opacity: CGFloat) -> UIImage {
        // Keep the bubble's cutout and the surrounding canvas transparent. The
        // repair-photo renderer deliberately uses black and must remain separate.
        let size = CGSize(width: 560, height: 320)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setAlpha(min(1, max(0, opacity)))
            if let bubble = UIImage(named: "FixiBubble"), bubble.size.width > 0, bubble.size.height > 0 {
                let scale = min(220 / bubble.size.width, 220 / bubble.size.height)
                let fitted = CGSize(width: bubble.size.width * scale, height: bubble.size.height * scale)
                bubble.draw(in: CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                                       width: fitted.width, height: fitted.height))
            }
        }
    }
}
