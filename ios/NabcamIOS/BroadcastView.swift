import HaishinKit
import AVFoundation
import UniformTypeIdentifiers
import SwiftUI
import NabcamCore

private let nabPurple = Color(red: 0.64, green: 0.43, blue: 1)
private let nabGreen = Color(red: 0.05, green: 0.81, blue: 0.63)

/// Short hints stay beside the setting, without creating another Form row.
private struct SettingLabel: View {
    let title: String
    let hint: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(title)
                Text(hint).font(.subheadline).foregroundStyle(nabPurple)
            }
            Text(title)
        }.accessibilityLabel(title).accessibilityHint(hint)
    }
}

private struct SettingsHelp: View {
    let title: String
    let detail: String
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: {
            Label(title, systemImage: "info.circle").font(.subheadline)
        }.foregroundStyle(nabPurple)
            .alert(title, isPresented: $presented) {
                Button("Done", role: .cancel) {}
            } message: { Text(detail) }
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case hub = "Hub", camera = "Camera", connection = "Connection", video = "Video"
    case audio = "Audio", overlay = "Overlay", advanced = "Advanced"
    var id: String { rawValue }
}

struct BroadcastView: View {
    @StateObject private var model = BroadcastModel()
    @StateObject private var chat = StreamChatService()
    @StateObject private var twitchLogin = TwitchLoginStore()
    @StateObject private var chatEmotes = ChatEmoteCache()
    @StateObject private var connections = ConnectionProfiles()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var confirmLive = false
    @State private var profileID: UUID?
    @State private var profileName = ""
    @State private var confirmDelete = false
    @State private var profileNotice: String?
    @State private var destination = ""
    // These are device-local preferences, not connection credentials. Selecting
    // a destination or relaunching must not silently reset the requested rates.
    @AppStorage("stream.targetBitrateKbps") private var bitrate = 1600
    @AppStorage("stream.videoCodec") private var videoCodec: VideoCodecChoice = .h264
    @AppStorage("stream.audioBitrateKbps") private var audioBitrate: AudioBitrate = .kbps96
    @State private var chatChannel = ""
    @State private var chatProvider = "kick"
    @State private var twitchChannel = ""
    @State private var twitchUsername = ""
    @State private var twitchToken = ""
    @State private var chatSetupError: String?
    @State private var importWatermark = false
    @State private var settingsPage: SettingsPage = .hub
    @AppStorage("hub.settingsOnLeft") private var settingsOnLeft = false
    @AppStorage("hub.showFlashlightButton") private var showFlashlightButton = false
    @AppStorage("hub.showLiveFPS") private var showLiveFPS = true
    @AppStorage("hub.leftHandedMode") private var leftHandedMode = false
    @AppStorage("hub.showResolution") private var showResolution = true
    @AppStorage("hub.showUploadData") private var showUploadData = false
    @AppStorage("hub.showCompositionGrid") private var showCompositionGrid = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            BrowserHostView(host: model.browserHost).ignoresSafeArea().allowsHitTesting(false)
            CapturePreview(mixer: model.browserPreviewMixer ?? model.mixer)
                .id(ObjectIdentifier(model.browserPreviewMixer ?? model.mixer)).ignoresSafeArea()
            if showCompositionGrid, model.isReady, !model.isBusy, let size = model.previewDimensions {
                PreviewCompositionGrid(frameSize: size).ignoresSafeArea()
            }
            VStack {
                HStack(alignment: .top) {
                    if settingsOnLeft != leftHandedMode {
                        settingsButton
                        Spacer()
                        statusHUD
                    } else {
                        statusHUD
                        Spacer()
                        settingsButton
                    }
                }
                Spacer()
                if chat.isEnabled {
                    HStack {
                        if leftHandedMode { Spacer() }
                        ChatOverlayView(chat: chat).frame(maxWidth: 380)
                        if !leftHandedMode { Spacer() }
                    }.frame(maxHeight: 200, alignment: .bottom).clipped()
                }
                HStack {
                    if leftHandedMode { cameraControls } else { microphoneControls }
                    Spacer()
                    if model.isConnecting {
                        Button("CANCEL") { Task { await model.stop() } }
                    } else if model.isLive {
                        Button("STOP", role: .destructive) { Task { await model.stop() } }
                    } else if model.isBusy {
                        ProgressView().tint(nabGreen)
                    } else {
                        Button("START") { confirmLive = true }.disabled(!model.isReady)
                    }
                    Spacer()
                    if leftHandedMode { microphoneControls } else { cameraControls }
                }
                .buttonStyle(.borderedProminent).tint(nabGreen).foregroundStyle(.black)
            }.padding(20)
        }
        .task { connections.load(); loadTwitchLogin(); await model.setActive(true) }
        .task(id: model.streamChatEnabled && model.isReady) {
            guard model.streamChatEnabled, model.isReady else {
                chatEmotes.stop()
                return
            }
            var previousMessages: [ChatMessage]?
            var previousEmotes: Set<URL> = []
            while !Task.isCancelled {
                let messages = chat.isEnabled ? Array(chat.messages.suffix(8)) : []
                chatEmotes.update(messages: messages)
                let loadedEmotes = Set(chatEmotes.images.keys)
                if previousMessages != messages || previousEmotes != loadedEmotes {
                    await model.updateStreamChat(messages: messages, emotes: chatEmotes.images)
                    previousMessages = messages
                    previousEmotes = loadedEmotes
                }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)) { notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            switch type {
            case .began: model.handleAudioInterruption(began: true)
            case .ended: model.handleAudioInterruption(began: false)
            @unknown default: break
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { chat.disconnect(); Task { await model.setActive(false) } }
            else if phase == .active { Task { await model.setActive(true) } }
        }
        .fullScreenCover(isPresented: $showSettings) {
            NavigationStack {
                VStack(spacing: 0) {
                settingsNavigation
                Form {
                    if settingsPage == .hub {
                    Section("Hub") {
                        Toggle("Live FPS", isOn: $showLiveFPS)
                            .accessibilityIdentifier("hub-fps-toggle")
                        Toggle("Show resolution", isOn: $showResolution)
                            .accessibilityIdentifier("hub-resolution-toggle")
                        Toggle(isOn: $showUploadData) {
                            SettingLabel(title: "Upload data used", hint: "This broadcast only")
                        }
                            .accessibilityIdentifier("hub-upload-toggle")
                        Toggle(isOn: $showCompositionGrid) {
                            SettingLabel(title: "Rule-of-thirds grid", hint: "Preview only")
                        }
                            .accessibilityIdentifier("hub-grid-toggle")
                        Toggle(isOn: $leftHandedMode) {
                            SettingLabel(title: "Left-handed mode", hint: "Camera controls on left")
                        }
                            .accessibilityIdentifier("hub-left-handed-toggle")
                        Toggle(isOn: $settingsOnLeft) {
                            SettingLabel(title: "Swap Settings and status", hint: "Keep other controls in place")
                        }
                            .accessibilityIdentifier("hub-swap-toggle")
                        Toggle(isOn: $showFlashlightButton) {
                            SettingLabel(title: "Show flashlight button", hint: "Above Chat, when available")
                        }
                            .accessibilityIdentifier("hub-flashlight-toggle")
                    }
                    }
                    if settingsPage == .camera {
                    Section("Camera") {
                        cameraMenu
                        Toggle("Mirror front camera", isOn: Binding(get: { model.mirrorFrontCamera }, set: { value in
                            Task { await model.setFrontCameraMirrored(value) }
                        })).disabled(!model.isReady || model.isBusy || model.isLive)
                        SettingsHelp(title: "About mirroring", detail: "Matches the selfie preview and outgoing video. Rear camera stays unmirrored. Change before going live.")
                        if model.maximumZoom > model.minimumZoom {
                            LabeledContent("Zoom", value: String(format: "%.1f×", model.zoom))
                            Slider(value: Binding(get: { model.zoom }, set: { value in Task { await model.setZoom(value) } }),
                                   in: model.minimumZoom...model.maximumZoom)
                                .accessibilityLabel("Camera zoom")
                                .disabled(!model.isReady || model.isBusy)
                            SettingsHelp(title: "Digital zoom", detail: "Zoom crops the selected camera image and can reduce detail. Use the Camera menu to switch physical lenses.")
                        } else { Text("Zoom is unavailable on this camera.").font(.caption) }
                        if model.canLockFocus {
                            Toggle("Lock focus", isOn: Binding(get: { model.isFocusLocked }, set: { value in
                                Task { await model.setFocusLocked(value) }
                            })).disabled(!model.isReady || model.isBusy)
                        }
                        if model.canLockExposure {
                            Toggle("Lock exposure", isOn: Binding(get: { model.isExposureLocked }, set: { value in
                                Task { await model.setExposureLocked(value) }
                            })).disabled(!model.isReady || model.isBusy)
                        }
                        if model.hasTorch {
                            Toggle("Flashlight", isOn: Binding(get: { model.isTorchOn }, set: { value in
                                if value != model.isTorchOn { Task { await model.toggleTorch() } }
                            })).disabled(!model.isReady || model.isBusy)
                        } else { Text("This camera has no flashlight.").font(.caption) }
                    }
                    }
                    if settingsPage == .connection {
                    Section("Connection") {
                        Menu("Saved connections") {
                            Button("New connection") {
                                profileID = nil; profileName = ""; destination = ""; profileNotice = nil
                            }
                            ForEach(connections.profiles) { profile in
                                Button(profile.name) {
                                    profileID = profile.id; profileName = profile.name
                                    destination = profile.destination; bitrate = profile.bitrateKbps
                                    videoCodec = profile.videoCodec ?? .h264
                                    audioBitrate = profile.audioBitrate ?? .kbps96
                                    chatChannel = profile.chatChannel; profileNotice = nil
                                    Task { await model.configureVideo(profile.videoPreset ?? .hd30) }
                                }
                            }
                        }.disabled(model.isLive || model.isBusy)
                        TextField("Connection name", text: $profileName)
                            .disabled(model.isLive || model.isBusy)
                        SecureField("Full RTMP / RTMPS / SRT / SRTLA URL", text: $destination)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(model.isLive || model.isBusy)
                        SettingsHelp(title: "Connection help", detail: "Include your stream key in the URL. Save stores the connection, video mode, codec, bitrates and chat channel securely on this device. Unsaved edits stay in memory.")
                        if let latency = try? SrtLatencySetting(destination) {
                            Menu {
                                Button("Use default") { setSrtLatency(nil) }
                                ForEach([120, 250, 500, 1000, 1500, 2500, 4000], id: \.self) { value in
                                    Button(String(value) + " ms") { setSrtLatency(value) }
                                }
                            } label: {
                                HStack {
                                    Text("SRT latency")
                                    Spacer()
                                    Text(latency.milliseconds.map { "\($0) ms" } ?? "Default")
                                }
                            }.disabled(model.isLive || model.isBusy)
                                .accessibilityIdentifier("srt-latency-menu")
                            Text("More buffering can help recover lost packets, but adds delay. The receiver may require more. Save to remember this connection’s value.")
                                .font(.caption).foregroundStyle(nabPurple)
                        }
                        Toggle("Experimental SRTLA", isOn: Binding(get: { model.experimentalSrtlaEnabled }, set: {
                            model.setExperimentalSrtla($0)
                        })).disabled(model.isLive || model.isBusy).accessibilityIdentifier("experimental-srtla-toggle")
                        if model.experimentalSrtlaEnabled {
                            Text("Use srtla:// with an SRTLA receiver. Tries Wi-Fi plus iOS’s selected cellular connection; it cannot select both SIMs. Real-iPhone failover and A/V sync are unverified. This test option resets when the app restarts.")
                                .font(.caption).foregroundStyle(nabPurple)
                                .accessibilityIdentifier("srtla-experimental-notice")
                        }
                        Button(profileID == nil ? "Save connection" : "Save changes") { saveConnection() }
                            .disabled(model.isLive || model.isBusy || !connections.canWrite)
                        if profileID != nil {
                            Button("Delete saved connection", role: .destructive) { confirmDelete = true }
                                .disabled(model.isLive || model.isBusy || !connections.canWrite)
                        }
                        if let error = connections.errorMessage {
                            Text(error).font(.caption).foregroundStyle(.red)
                            Button("Retry loading connections") { connections.load() }
                                .disabled(model.isLive || model.isBusy)
                        }
                        if let profileNotice { Text(profileNotice).font(.caption).foregroundStyle(nabPurple) }
                    }
                    }
                    if settingsPage == .video {
                    Section("Video") {
                        Picker("Video codec", selection: $videoCodec) {
                            Text("H.264").tag(VideoCodecChoice.h264)
                            Text(model.hardwareHEVC ? "HEVC (H.265)" : "HEVC — hardware unavailable")
                                .tag(VideoCodecChoice.hevc).disabled(!model.hardwareHEVC)
                        }.disabled(model.isLive || model.isBusy)
                            .accessibilityIdentifier("video-codec-picker")
                        if videoCodec == .hevc {
                            Text("HEVC Main, 8-bit. SRT/SRTLA only in this build; your receiver and onward service must support it. Real-iPhone encoding and playback still need testing.")
                                .font(.caption).foregroundStyle(nabPurple)
                        }
                        Picker("Resolution / FPS", selection: Binding(get: { model.videoPreset }, set: { preset in
                            Task { await model.configureVideo(preset) }
                        })) {
                            ForEach(VideoPreset.allCases) { Text($0.label).tag($0) }
                        }.disabled(model.isLive || model.isBusy)
                        Picker("Target bitrate", selection: $bitrate) {
                            ForEach([444, 800, 1200, 1600, 2500, 4000, 6000], id: \.self) { Text("\($0) kbps").tag($0) }
                        }.disabled(model.isLive || model.isBusy)
                            .accessibilityIdentifier("video-bitrate-picker")
                        SettingsHelp(title: "Bitrate and FPS", detail: "Target bitrate is the requested average video rate, not a minimum. Adaptive bitrate is not included yet. The HUD measures local camera and compositor FPS, not receiver FPS. Unsupported camera modes show an error.")
                    }
                    }
                    if settingsPage == .audio {
                    Section("Audio") {
                        Picker("AAC bitrate", selection: $audioBitrate) {
                            ForEach(AudioBitrate.allCases) { Text($0.label).tag($0) }
                        }.disabled(model.isLive || model.isBusy)
                            .accessibilityIdentifier("audio-bitrate-picker")
                        SettingsHelp(title: "Audio quality", detail: "96 kbps is the default. Higher rates use more upload data, but do not make the microphone louder. Change before going live.")
                        Toggle("Mute microphone", isOn: Binding(get: { model.isMuted }, set: { value in
                            if value != model.isMuted { Task { await model.toggleMute() } }
                        })).disabled(!model.isReady || model.isBusy)
                        Toggle("Microphone processing · experimental", isOn: $model.microphoneProcessingEnabled)
                            .disabled(model.isLive || model.isBusy)
                            .accessibilityIdentifier("microphone-processing-toggle")
                        if model.microphoneProcessingEnabled {
                            Stepper("Microphone gain: \(model.microphoneGainDB) dB", value: $model.microphoneGainDB, in: -12...24)
                                .disabled(model.isLive || model.isBusy)
                                .accessibilityIdentifier("microphone-gain-stepper")
                            Toggle("Peak limiter", isOn: $model.microphoneLimiterEnabled)
                                .disabled(model.isLive || model.isBusy)
                            Text("Applies gain before encoding; limiter ceiling is −1 dBFS. The HUD meter shows input levels before this stage. Change before going live. Device testing is still needed.")
                                .font(.caption).foregroundStyle(nabPurple)
                        }
                    }
                    }
                    if settingsPage == .overlay {
                    Section("Chat") {
                        Picker("Chat service", selection: $chatProvider) {
                            Text("Kick").tag("kick")
                            Text("Twitch").tag("twitch")
                        }.accessibilityIdentifier("chat-provider-picker")
                            .onChange(of: chatProvider) { _ in chat.disconnect(); chatSetupError = nil }
                        if chatProvider == "kick" {
                            TextField("Kick channel name", text: $chatChannel)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        } else {
                            TextField("Twitch channel name", text: $twitchChannel)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("Twitch username", text: $twitchUsername)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            SecureField("Twitch chat token", text: $twitchToken)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Text("Use a user token with chat:read for this username. Read-only chat; login is saved in this device’s Keychain. Switching service disconnects chat.")
                                .font(.caption).foregroundStyle(nabPurple)
                            if let error = twitchLogin.errorMessage {
                                Text(error).font(.caption).foregroundStyle(.red)
                                Button("Retry loading Twitch login") { loadTwitchLogin() }
                            }
                            Button("Forget saved Twitch login", role: .destructive) {
                                chat.disconnect()
                                if twitchLogin.forget() {
                                    twitchToken = ""; twitchUsername = ""; twitchChannel = ""
                                }
                            }.disabled(!twitchLogin.canWrite)
                        }
                        Button(chat.isEnabled ? "Disconnect chat" : "Connect chat") {
                            if chat.isEnabled { chat.disconnect() }
                            else { connectSelectedChat() }
                        }
                        if let chatSetupError { Text(chatSetupError).font(.caption).foregroundStyle(.red) }
                        Text(chat.status).font(.caption).foregroundStyle(.secondary)
                        Toggle("Include chat in stream · experimental", isOn: Binding(
                            get: { model.streamChatEnabled },
                            set: { enabled in Task { await model.setStreamChatEnabled(enabled) } }))
                            .disabled(model.isLive || model.isBusy)
                            .accessibilityIdentifier("stream-chat-toggle")
                        Text("Adds chat at the bottom left of your broadcast. Change before going live. Chat disconnects when you leave the app.").font(.caption)
                    }
                    Section("Stream overlays") {
                        ForEach(Array(model.watermarks.enumerated()), id: \.element.id) { index, watermark in
                            LabeledContent("Watermark \(index + 1)", value: "PNG / JPEG")
                            Toggle("DVD bounce", isOn: Binding(get: { watermark.dvd == true }, set: { enabled in
                                Task { await model.configureWatermark(id: watermark.id, dvd: enabled) }
                            })).disabled(model.isLive || model.isBusy)
                            Picker("Position", selection: Binding(get: { watermark.corner }, set: { corner in
                                Task { await model.configureWatermark(id: watermark.id, corner: corner) }
                            })) {
                                ForEach(ClockCorner.allCases) { Text($0.rawValue).tag($0) }
                            }.disabled(model.isLive || model.isBusy || watermark.dvd == true)
                            Picker("Width", selection: Binding(get: { watermark.percent }, set: { percent in
                                Task { await model.configureWatermark(id: watermark.id, percent: percent) }
                            })) {
                                ForEach([5, 10, 15, 20, 25, 30, 40], id: \.self) { Text("\($0)%").tag($0) }
                            }.disabled(model.isLive || model.isBusy)
                            Button("Remove watermark \(index + 1)", role: .destructive) {
                                Task { await model.configureWatermark(id: watermark.id, remove: true) }
                            }.disabled(model.isLive || model.isBusy)
                        }
                        Button("Add image watermark") { importWatermark = true }
                            .disabled(model.isLive || model.isBusy || model.watermarks.count >= 3)
                        Text("Up to 3 PNG/JPEG images, 4 MB each, saved on this phone without cloud backup. Transparent PNGs keep their transparency; tall images are limited to 40% of video height.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let message = model.overlayStorageMessage {
                            Text(message).font(.caption).foregroundStyle(.red)
                            Button("Retry loading saved overlays") { Task { await model.retrySavedOverlays() } }
                                .disabled(model.isLive || model.isBusy)
                        }
                        Toggle("Clock in video", isOn: Binding(get: { model.clockEnabled }, set: { value in
                            Task { await model.configureClock(enabled: value, corner: model.clockCorner) }
                        })).disabled(model.isLive || model.isBusy)
                        if model.clockEnabled {
                            Picker("Clock position", selection: Binding(get: { model.clockCorner }, set: { corner in
                                Task { await model.configureClock(enabled: true, corner: corner) }
                            })) {
                                ForEach(ClockCorner.allCases) { Text($0.rawValue).tag($0) }
                            }.disabled(model.isLive || model.isBusy)
                        }
                        Text("Local time in preview and outgoing video. Change before going live; preview restarts. Compositing performance still needs iPhone testing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    BrowserSourceSettings(store: model.browserSources, locked: model.isLive || model.isBusy) {
                        await model.restartPreview()
                    }
                    }
                    if settingsPage == .advanced {
                    Section("About this iOS build") {
                        NavigationLink("Open-source acknowledgments") { AcknowledgmentsView() }
                        Text("Calls and other microphone interruptions stop the stream. Preview resumes when available; tap Start to go live again.").font(.caption)
                        Text("SRTLA and browser overlays are experimental and need device testing. Dual-SIM bonding, USB cameras, purchases and background broadcasting are not included yet. Twitch chat requires a user token; automatic sign-in is not included. Live camera switching keeps the transport running, but switching gaps and A/V sync still need real-iPhone testing.").font(.caption)
                        Button("Restart camera preview") { Task { await model.restartPreview() } }
                            .disabled(model.isLive || model.isBusy)
                    }
                    Section("Diagnostics") {
                        ShareLink("Share diagnostic timeline", item: model.diagnosticReport)
                        Button("Clear diagnostic timeline", role: .destructive) { model.clearDiagnostics() }
                        Text("Last 300 events: FPS, frame gaps and SRTLA queues, local send rates, retries and relay ACK timing. No stream keys or chat contents. Local sends do not prove receiver delivery or audio sync.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    }
                }
                .id(settingsPage)
                .accessibilityIdentifier("settings-form")
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
            }.tint(nabPurple)
            .fileImporter(isPresented: $importWatermark, allowedContentTypes: [.png, .jpeg]) { result in
                switch result {
                case .success(let url): Task { await model.importWatermark(from: url) }
                case .failure: model.errorMessage = "The image could not be selected. Try opening it from Files again."
                }
            }
            .confirmationDialog("Delete this saved connection?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let id = profileID, connections.delete(id: id) {
                        profileID = nil; profileName = ""; destination = ""
                        profileNotice = "Saved connection deleted."
                    }
                }
            }
        }
        .confirmationDialog("Start broadcasting camera and microphone?", isPresented: $confirmLive, titleVisibility: .visible) {
            Button("Go live") { model.start(destination: destination, bitrateKbps: bitrate, codec: videoCodec, audioBitrate: audioBitrate) }
        }
        .alert("GNAB CAM IRL", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func loadTwitchLogin() {
        twitchLogin.load()
        if let login = twitchLogin.login {
            twitchChannel = login.channel; twitchUsername = login.username; twitchToken = login.token
        }
    }

    private func connectSelectedChat() {
        chatSetupError = nil
        if chatProvider == "kick" { chat.connect(channel: chatChannel); return }
        do {
            let login = try TwitchChatLogin(channel: twitchChannel, username: twitchUsername, token: twitchToken)
            guard twitchLogin.save(login) else {
                chatSetupError = "Load or unlock your saved Twitch login before connecting."
                return
            }
            chat.connectTwitch(login)
        } catch { chatSetupError = "Enter a Twitch channel, username, and valid chat token." }
    }

    private var settingsNavigation: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SettingsPage.allCases) { page in
                        Button { settingsPage = page } label: {
                            Text(page.rawValue).font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).frame(minHeight: 44)
                                .foregroundStyle(settingsPage == page ? Color.black : nabPurple)
                                .background(settingsPage == page ? nabPurple : Color.secondary.opacity(0.12),
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-tab-\(page.rawValue.lowercased())")
                        .accessibilityAddTraits(settingsPage == page ? .isSelected : [])
                        .id(page)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            .accessibilityIdentifier("settings-tabs")
            .onChange(of: settingsPage) { page in reader.scrollTo(page, anchor: .center) }
        }
    }

    private var microphoneControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isMuted ? "MUTED" : (model.audioLevel?.clipped == true ? "CLIP" : "AUDIO"))
                    .font(.caption2.bold()).foregroundStyle(.white)
                ProgressView(value: model.isMuted ? 0 : (model.audioLevel?.fraction ?? 0))
                    .tint(model.audioLevel?.clipped == true ? .red : nabGreen)
                Text(model.audioLevel.map { String(format: "PK %.0f dBFS", $0.peakDBFS) } ?? "No samples")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white)
            }
            .frame(width: 94).padding(8)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Local audio output level")
            Button(model.isMuted ? "MIC OFF" : "MIC ON") { Task { await model.toggleMute() } }
                .disabled(!model.isReady || model.isBusy)
        }
    }

    private var cameraControls: some View {
        VStack(spacing: 8) {
            if showFlashlightButton && model.hasTorch {
                Button { Task { await model.toggleTorch() } } label: {
                    Image(systemName: model.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                }.accessibilityLabel(model.isTorchOn ? "Turn flashlight off" : "Turn flashlight on")
                    .disabled(!model.isReady || model.isBusy)
            }
            Button(chat.isEnabled ? "CHAT ON" : "CHAT OFF") {
                if chat.isEnabled { chat.disconnect() }
                else if (chatProvider == "kick" ? chatChannel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : twitchChannel.isEmpty || twitchUsername.isEmpty || twitchToken.isEmpty) {
                    settingsPage = .overlay; showSettings = true
                } else { connectSelectedChat() }
            }.accessibilityIdentifier("preview-chat-toggle")
            if model.maximumZoom > model.minimumZoom {
                HStack {
                    ForEach([1.0, 3.0], id: \.self) { zoom in
                        if zoom >= model.minimumZoom && zoom <= model.maximumZoom {
                            Button("\(Int(zoom))×") { Task { await model.setZoom(zoom) } }
                                .accessibilityLabel("Zoom \(Int(zoom)) times")
                                .disabled(!model.isReady || model.isBusy)
                        }
                    }
                }
            }
            cameraMenu
            if model.canFlipCamera {
                Button(model.isFront ? "REAR CAMERA" : "SELFIE") { Task { await model.switchCamera() } }
                    .disabled(!model.isReady || model.isBusy)
            }
        }
    }

    private var cameraMenu: some View {
        Menu {
            ForEach(model.cameras) { camera in
                Button { Task { await model.selectCamera(camera.id) } } label: {
                    if camera.id == model.selectedCameraID {
                        Label(camera.name, systemImage: "checkmark")
                    } else { Text(camera.name) }
                }
            }
        } label: {
            Label(model.cameras.first(where: { $0.id == model.selectedCameraID })?.name ?? "Camera unavailable",
                  systemImage: "camera.rotate")
        }.accessibilityIdentifier("camera-selector")
            .disabled(!model.isReady || model.isBusy || model.cameras.count < 2)
    }

    private var settingsButton: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape.fill").frame(width: 48, height: 48)
        }
        .foregroundStyle(.black).background(nabPurple, in: Circle()).accessibilityLabel("Settings")
    }

    private var statusHUD: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GNAB CAM IRL · iOS Preview").font(.headline).foregroundStyle(nabPurple)
            Text(model.status).font(.caption).foregroundStyle(model.isLive ? nabGreen : .white)
                .accessibilityIdentifier("capture-status")
            if showResolution, let size = model.captureDimensions {
                Text(size.label).font(.caption.monospacedDigit()).foregroundStyle(.white)
                    .accessibilityLabel("Camera resolution \(size.width) by \(size.height)")
                    .accessibilityIdentifier("capture-resolution-readout")
            }
            if showLiveFPS, let capture = model.captureFPS, let mixed = model.mixedFPS {
                Text(String(format: "Camera %.1f · Output %.1f FPS", capture, mixed))
                    .font(.caption.monospacedDigit()).foregroundStyle(.white)
                    .accessibilityIdentifier("live-fps-readout")
            }
            if let paths = model.relayPathStatus {
                // Relay details describe individual paths; upload usage is the
                // whole broadcast, including paths that have since disappeared.
                Text(paths).font(.caption2).foregroundStyle(.white)
            }
            if showUploadData, let bytes = model.uploadedBytes {
                Text(UploadByteCounter.label(bytes: bytes))
                    .font(.caption.monospacedDigit()).foregroundStyle(nabGreen)
                    .accessibilityLabel("Local upload this broadcast: \(bytes) bytes")
                    .accessibilityIdentifier("upload-data-readout")
            }
            if let traffic = model.relayTrafficStatus {
                Text(traffic).font(.caption2.monospacedDigit()).foregroundStyle(.white)
                    .accessibilityLabel("Local UDP send rate and relay acknowledgment timing: \(traffic)")
            }
        }
        .padding(12).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("status-hud")
    }

    private func setSrtLatency(_ milliseconds: Int?) {
        do {
            destination = try SrtLatencySetting(destination).replacing(with: milliseconds)
            profileNotice = "Latency updated · save to remember"
        } catch {
            profileNotice = "Latency could not be changed. Check the connection URL’s latency options."
        }
    }

    private func saveConnection() {
        do {
            let profile = try ConnectionProfile(id: profileID ?? UUID(), name: profileName,
                destination: destination, bitrateKbps: bitrate, chatChannel: chatChannel, videoPreset: model.videoPreset,
                videoCodec: videoCodec, audioBitrate: audioBitrate)
            if connections.save(profile) {
                profileID = profile.id; profileName = profile.name
                profileNotice = "Saved securely on this iPhone."
            } else { profileNotice = nil }
        } catch { profileNotice = error.localizedDescription }
    }
}

private struct CapturePreview: UIViewRepresentable {
    let mixer: MediaMixer
    final class Coordinator {
        var task: Task<Void, Never>?
        var mixer: MediaMixer?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MTHKView {
        let view = MTHKView(frame: .zero)
        view.videoGravity = .resizeAspect
        context.coordinator.mixer = mixer
        context.coordinator.task = Task {
            await mixer.addOutput(view)
            if Task.isCancelled { await mixer.removeOutput(view) }
        }
        return view
    }
    func updateUIView(_ uiView: MTHKView, context: Context) {}
    static func dismantleUIView(_ uiView: MTHKView, coordinator: Coordinator) {
        coordinator.task?.cancel()
        let task = coordinator.task
        let mixer = coordinator.mixer
        Task {
            await task?.value
            await mixer?.removeOutput(uiView)
        }
    }
}

private struct BrowserHostView: UIViewRepresentable {
    let host: BrowserOverlayHost
    func makeUIView(context: Context) -> BrowserOverlayHost { host }
    func updateUIView(_ uiView: BrowserOverlayHost, context: Context) { }
}
