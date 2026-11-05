import SwiftUI
import PhotosUI
import AVKit

enum MendTheme {
    static let ink = Color(red: 0.027, green: 0.043, blue: 0.105)
    static let surface = Color(red: 0.065, green: 0.09, blue: 0.19)
    static let cyan = Color(red: 0.57, green: 0.87, blue: 1)
    static let blue = Color(red: 0.61, green: 0.74, blue: 1)
    static let violet = Color(red: 0.76, green: 0.68, blue: 1)
    static let mint = cyan
    static let muted = Color(red: 0.72, green: 0.77, blue: 0.88)
    static let glow = Color(red: 0.18, green: 0.29, blue: 0.95)
    static let primaryFill = LinearGradient(colors: [cyan, blue, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static func accent(_ experience: MendExperience) -> Color {
        switch experience {
        case .focus: cyan
        case .flow: violet
        case .guide: blue
        }
    }
}

struct FixiBackdrop: View {
    var body: some View {
        ZStack {
            MendTheme.ink
            RadialGradient(colors: [MendTheme.glow.opacity(0.25), .clear], center: .topLeading, startRadius: 0, endRadius: 460)
            RadialGradient(colors: [Color.purple.opacity(0.13), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 420)
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct FixiGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat
    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                if !reduceTransparency { shape.fill(.ultraThinMaterial) }
                shape.fill(MendTheme.surface.opacity(reduceTransparency ? 1 : 0.8))
                shape.fill(LinearGradient(colors: [.white.opacity(0.055), .clear, MendTheme.violet.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }.overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.18), MendTheme.blue.opacity(0.07), MendTheme.violet.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func fixiGlass(radius: CGFloat = 22) -> some View { modifier(FixiGlassSurface(radius: radius)) }
}

struct FixiWelcomeBrand: View {
    var body: some View {
        Image("FixiBubble").resizable().scaledToFit().frame(width: 88, height: 88)
            .shadow(color: MendTheme.glow.opacity(0.4), radius: 28, y: 10)
            .frame(maxWidth: .infinity).accessibilityLabel("Fixi")
    }
}

struct FixiView: View {
    @Bindable var model: FixiModel
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importTask: Task<Void, Never>?
    @State private var importID = UUID()
    private var parts: MendExperienceParts { MendExperienceParts(model: model, accent: MendTheme.accent(model.experience)) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        statusStrip
                        if model.isDemo, model.stage != .guide {
                            Label("Example", systemImage: "sparkle").font(.caption.weight(.semibold)).foregroundStyle(MendTheme.mint)
                        }
                        switch model.experience {
                        case .focus: MendFocusExperience(model: model)
                        case .flow: MendFlowExperience(model: model)
                        case .guide: MendGuideExperience(model: model)
                        }
                        if let error = model.errorMessage {
                            Text(error).font(.subheadline).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }.padding(22).id("mend-top")
                }.background { FixiBackdrop() }
                    .safeAreaInset(edge: .bottom, spacing: 0) { MendBottomBar(model: model) }
                    .onChange(of: model.stage) { _, _ in reader.scrollTo("mend-top", anchor: .top) }
                    .onChange(of: model.stepIndex) { _, _ in reader.scrollTo("mend-top", anchor: .top) }
                    .onChange(of: model.project) { _, _ in model.syncDisplay() }
                    .onChange(of: model.setupText) { _, _ in model.syncDisplay() }
                    .onChange(of: model.helpText) { _, _ in model.syncDisplay() }
                    .onChange(of: model.busy) { _, active in if active { reader.scrollTo("mend-top", anchor: .top) } }
                    .toolbar(.hidden, for: .navigationBar)
                    .sheet(isPresented: appSheetBinding) { appSheet }
                    .photosPicker(isPresented: presentationBinding(.library), selection: $selectedPhoto, matching: .images)
                    .onChange(of: selectedPhoto) { _, item in
                        guard let item else { return }
                        importTask?.cancel()
                        let id = UUID(); importID = id
                        let context = model.photoContextToken
                        importTask = Task {
                            defer { if importID == id { selectedPhoto = nil; importTask = nil } }
                            do {
                                guard let data = try await item.loadTransferable(type: Data.self) else { throw MendError.message("This photo could not be opened.") }
                                guard !Task.isCancelled, importID == id, model.photoContextToken == context else { return }
                                model.acceptPhoto(data, source: "Photo library", expectedToken: context)
                            } catch {
                                guard !Task.isCancelled, importID == id, model.photoContextToken == context else { return }
                                model.errorMessage = error.localizedDescription
                            }
                        }
                    }
            }
        }.preferredColorScheme(.dark).tint(MendTheme.blue)
    }
    private func presentationBinding(_ expected: MendPresentation) -> Binding<Bool> {
        Binding(get: { model.presentation == expected }, set: { if !$0 { model.closePresentation(expected) } })
    }
    private var appSheetBinding: Binding<Bool> {
        let expected = model.presentation
        return Binding(get: { model.presentation != nil && model.presentation != .library }, set: { shown in
            if !shown, let expected, expected != .library { model.closePresentation(expected) }
        })
    }
    @ViewBuilder private var appSheet: some View {
        Group {
            switch model.presentation {
            case .comparison: comparisonSheet
            case .settings: MendSettings(model: model)
            case .preview: displayPreview
            case .photo: photoDetail
            case .actions: actionsSheet
            case .checklist: checklistSheet
            case .details: detailsSheet
            case .sources: sourcesSheet
            case .audioOutput: audioOutputSheet
            case .camera:
                let context = model.cameraSheetToken
                PhoneCamera(onPhoto: { model.acceptPhoto($0, source: "iPhone camera", expectedToken: context) },
                            onDismiss: { model.perform(.closePicker) })
            case .library, nil: EmptyView()
            }
        }.safeAreaInset(edge: .bottom, spacing: 0) {
            if model.presentation != .camera { MendBottomBar(model: model) }
        }.preferredColorScheme(.dark)
    }
    private func sheetPage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(title).font(.title2.weight(.semibold))
                content()
            }.padding(22)
        }.background { FixiBackdrop() }
    }
    @ViewBuilder private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The bottom bar owns microphone startup/shutdown feedback. Keep
            // this strip for repair work so a screen never repeats the same cue.
            if model.progressTitle != nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(MendTheme.mint)
                    Text(model.statusText).font(.subheadline).foregroundStyle(MendTheme.muted)
                }
            }
            if model.presentation == nil, [.welcome, .capture, .confirmation].contains(model.stage), let answer = model.lastAnswer, !answer.isEmpty {
                Text(answer).font(.subheadline).lineSpacing(3).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .fixiGlass(radius: 18)
            }
            if let notice = model.voiceNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
        }
    }
    private func actionRow(_ action: MendAction) -> some View {
        Button { model.perform(action.id) } label: {
            HStack(spacing: 14) {
                Text(action.title).font(.body)
                Spacer(minLength: 5)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(MendTheme.muted)
            }.frame(minHeight: 52).padding(.horizontal, 16).contentShape(Rectangle())
                .fixiGlass(radius: 14)
        }.buttonStyle(.plain).disabled(!model.isEnabled(action.id))
    }
    private var comparisonSheet: some View {
        sheetPage("Choose a layout") {
            Text("Your repair stays with you.").font(.subheadline).foregroundStyle(MendTheme.muted)
            VStack(spacing: 10) {
                ForEach(MendExperience.allCases) { experience in
                    let action: MendActionID = experience == .focus ? .useFocus : experience == .flow ? .useFlow : .useGuide
                    Button { model.perform(action) } label: {
                        HStack(spacing: 17) {
                            Image(systemName: experience.symbol).font(.title2).frame(width: 30)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(experience.title).font(.headline)
                                Text(experience.principle).font(.subheadline).foregroundStyle(MendTheme.muted)
                            }
                            Spacer()
                            if model.experience == experience { Image(systemName: "checkmark") }
                        }.padding(19).frame(maxWidth: .infinity, alignment: .leading)
                            .fixiGlass(radius: 18)
                    }.buttonStyle(.plain).disabled(!model.isEnabled(action))
                        .accessibilityLabel(experience.title).accessibilityValue(model.experience == experience ? "Selected" : "")
                }
            }
        }
    }
    private var checklistSheet: some View {
        sheetPage("Checklist") { statusStrip; parts.progress; parts.checklist }
    }
    private var photoDetail: some View {
        sheetPage(model.photoIsFocused ? "Close-up" : "Full photo") {
            if let image = model.annotatedImage {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
            } else { Text("No photo is available.").foregroundStyle(MendTheme.muted) }
        }
    }
    private var detailsSheet: some View {
        sheetPage("Let’s work through it.") {
            statusStrip
            if let answer = model.lastAnswer, !answer.isEmpty {
                VStack(alignment: .leading, spacing: 15) {
                    parts.liveAnswerPhoto
                    Text(.init(answer)).font(.body).lineSpacing(4).textSelection(.enabled).tint(MendTheme.mint)
                }
            } else if model.stage == .guide, let step = model.currentStep {
                Text(step.title).font(.title3.weight(.semibold))
                parts.stepText
            } else if !model.voice.outputTranscript.isEmpty {
                Text(model.voice.outputTranscript).font(.body).foregroundStyle(MendTheme.muted)
            }
            TextField("Ask about this repair…", text: $model.helpText)
                .submitLabel(.send).onSubmit { if model.isEnabled(.submitQuestion) { model.perform(.submitQuestion) } }
                .padding(17).fixiGlass(radius: 22)
                .disabled(model.busy)
            VStack(spacing: 8) {
                ForEach(model.availableActions.filter { [.showLiveFullPhoto, .focusLivePhoto, .showSources].contains($0.id) }) { action in actionRow(action) }
            }
            if let diagnosis = model.diagnosis, model.lastAnswer == nil, model.stage != .guide {
                Text(diagnosis.summary).font(.subheadline).foregroundStyle(MendTheme.muted)
                parts.cautions
                ForEach(diagnosis.questions, id: \.self) { Text($0).font(.subheadline) }
            }
        }
    }
    private var sourcesSheet: some View {
        sheetPage("Sources") {
            if model.answerSources.isEmpty { Text("No sources were returned.").font(.subheadline).foregroundStyle(MendTheme.muted) }
            VStack(spacing: 8) {
                ForEach(Array(model.answerSources.prefix(model.sourceActions.count).enumerated()), id: \.offset) { index, source in
                    Button { model.openSource(index) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(source.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                Text(source.url.host ?? source.url.absoluteString).font(.caption).foregroundStyle(MendTheme.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .fixiGlass(radius: 14)
                    }.buttonStyle(.plain).accessibilityLabel("Open source \(index + 1)").accessibilityHint(source.title)
                }
            }
        }
    }
    private var actionsSheet: some View {
        sheetPage("Menu") {
            if model.voice.isActive {
                Text(model.voice.listeningMode == .oneTurn ? "Tap or pinch Talk, then ask or say a button name." : "Say a button name.")
                    .font(.caption).foregroundStyle(MendTheme.muted)
            }
            VStack(spacing: 8) { ForEach(model.menuActions) { action in actionRow(action) } }
        }
    }
    private var displayPreview: some View {
        sheetPage("Glasses preview") {
            if let image = model.annotatedImage { Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16)) }
            ForEach(Array(model.displayPages.enumerated()), id: \.offset) { index, page in
                VStack(alignment: .leading, spacing: 8) {
                    Text("CARD \(index + 1)").font(.caption2.monospaced()).foregroundStyle(MendTheme.mint)
                    Text(page).font(.title3)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18).fixiGlass(radius: 16)
            }
            Text("Content preview. Physical readability depends on the glasses.").font(.caption).foregroundStyle(MendTheme.muted)
        }
    }
    private var audioOutputSheet: some View {
        sheetPage("Glasses audio") {
            Text("Select your glasses in the system picker.").font(.subheadline).foregroundStyle(MendTheme.muted)
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Audio output").font(.body.weight(.medium))
                    Text(model.audioOutput.routeName).font(.caption).foregroundStyle(MendTheme.muted)
                }
                Spacer()
                MendAudioRoutePicker().frame(width: 54, height: 54).accessibilityLabel("System audio output picker")
            }.padding(16).fixiGlass(radius: 18)
            if let message = model.audioOutput.message { Text(message).font(.footnote).foregroundStyle(.orange) }
        }
    }
}

/// At most three app actions. Camera and microphone indicators never act as controls.
private struct MendBottomBar: View {
    @Bindable var model: FixiModel
    private var accent: Color { MendTheme.accent(model.experience) }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if model.liveViewEnabled || model.voice.isActive || model.voiceStarting || model.voiceStopping {
                HStack(alignment: .top, spacing: 14) {
                    if model.liveViewEnabled || model.voice.isActive || model.voiceStarting || model.voiceStopping {
                        Label(model.liveViewStatus, systemImage: model.liveViewEnabled ? "video.fill" : "video.slash")
                            .foregroundStyle(model.liveViewEnabled ? MendTheme.cyan : MendTheme.muted)
                    }
                    Spacer(minLength: 0)
                    if model.voice.isActive {
                        Label(model.voiceInputLabel, systemImage: model.voiceInputIsOpen ? "waveform" : "mic.slash")
                            .foregroundStyle(model.voiceInputIsOpen ? MendTheme.mint : MendTheme.muted)
                    } else if model.voiceStarting || model.voiceStopping {
                        Text(model.voiceStatus).foregroundStyle(MendTheme.muted)
                    }
                }.font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = model.liveViewNotice, !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.orange) }
            HStack(spacing: 10) {
                ForEach(Array(model.bottomActions.prefix(3).enumerated()), id: \.element.id) { index, action in
                    Button { model.perform(action.id) } label: {
                        Text(action.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                            .minimumScaleFactor(0.85).frame(maxWidth: .infinity).frame(minHeight: 54)
                            .padding(.horizontal, 9)
                            .foregroundStyle(index == 0 ? MendTheme.ink : Color.primary)
                            .background {
                                if index == 0 {
                                    RoundedRectangle(cornerRadius: 19, style: .continuous).fill(MendTheme.primaryFill)
                                } else {
                                    RoundedRectangle(cornerRadius: 19, style: .continuous).fill(MendTheme.surface)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(.white.opacity(index == 0 ? 0.3 : 0.13), lineWidth: 1))
                    }.buttonStyle(.plain).disabled(!action.enabled || !model.isEnabled(action.id))
                        .opacity(action.enabled ? 1 : 0.45).accessibilityLabel(action.title)
                }
            }
        }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 10)
            .background(.ultraThinMaterial)
            .background(MendTheme.ink.opacity(0.95))
            .overlay(alignment: .top) { Rectangle().fill(LinearGradient(colors: [.clear, MendTheme.blue.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing)).frame(height: 1) }
    }
}

private struct MendSettings: View {
    @Bindable var model: FixiModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.title2.weight(.semibold)).padding(22)
            Form {
                Section("Repair assistant · Meta") {
                    SecureField("Meta Model API key", text: $model.metaKeyDraft).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save Meta key") { model.perform(.saveKey) }.disabled(!model.isEnabled(.saveKey))
                    Button("Forget Meta key", role: .destructive) { model.perform(.forgetKey) }.disabled(!model.isEnabled(.forgetKey))
                }
                Section("Voice & source lookups · OpenAI") {
                    Text("OpenAI Realtime voice").fontWeight(.semibold)
                    SecureField("OpenAI API key", text: $model.voiceKeyDraft).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save OpenAI key") { model.perform(.saveVoiceKey) }.disabled(!model.isEnabled(.saveVoiceKey))
                    Button("Forget OpenAI key", role: .destructive) { model.perform(.forgetVoiceKey) }.disabled(!model.isEnabled(.forgetVoiceKey))
                    Text("Required for spoken replies and Find tips. Enter your key here privately.").font(.footnote)
                }
                Section("Spoken replies") {
                    Text(model.voiceStatus).font(.footnote).foregroundStyle(MendTheme.muted)
                    ForEach(model.voiceActions) { action in
                        Button(action.title) { model.perform(action.id) }.disabled(!model.isEnabled(action.id))
                    }
                    if let notice = model.voiceNotice { Text(notice).font(.footnote).foregroundStyle(.orange) }
                }
                Section("Microphone") {
                    Text("Glasses starts the microphone and camera. Speak naturally—no wake word or Talk button.").font(.footnote)
                    Text("Choose Mute mic when talking to someone nearby, then Unmute mic to continue. Nearby voices may still be heard while listening.").font(.footnote)
                }
                Section("Audio") {
                    Text("Output: " + model.audioOutput.routeName).font(.footnote)
                    Button("Test sound") { model.perform(.testSound) }.disabled(!model.isEnabled(.testSound))
                    if model.audioOutput.testPlaying { Button("Stop sound test") { model.perform(.stopSound) }.disabled(!model.isEnabled(.stopSound)) }
                    Button("Audio output") { model.perform(.audioOutput) }.disabled(!model.isEnabled(.audioOutput))
                    if let message = model.audioOutput.message { Text(message).font(.footnote) }
                    Text("Select your glasses in the iPhone’s system audio picker to hear spoken replies there.").font(.footnote)
                }
                Section("Glasses") {
                    Text(model.glasses.status).font(.footnote)
                    if let notice = model.glasses.navigationNotice { Text(notice).font(.footnote).foregroundStyle(MendTheme.muted) }
                    ForEach(model.connectionActions) { action in
                        Button(action.title) { model.perform(action.id) }.disabled(!model.isEnabled(action.id))
                    }
                }
                if let status = model.settingsMessage {
                    Section { Text(status).font(.footnote) }
                }
                Section("Your photos and conversation") { Text("Selected photos, fresh camera views, and repair details go to Meta when you request analysis. Repair questions include recent conversation and saved repair observations. OpenAI voices the answer text and handles requested web lookups. Your keys stay in this app’s Keychain; repair sessions stay in memory. Microphone and camera start when you choose Glasses.") }
                
            }.scrollContentBackground(.hidden).background { FixiBackdrop() }
        }.background { FixiBackdrop() }.preferredColorScheme(.dark).tint(MendTheme.blue)
    }
}

private struct MendAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(MendTheme.mint)
        view.activeTintColor = UIColor(MendTheme.mint)
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

private struct PhoneCamera: UIViewControllerRepresentable {
    let onPhoto: (Data) -> Void
    let onDismiss: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController(); controller.sourceType = .camera; controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: PhoneCamera
        init(_ parent: PhoneCamera) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onDismiss() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) { parent.onPhoto(data) }
            parent.onDismiss()
        }
    }
}
