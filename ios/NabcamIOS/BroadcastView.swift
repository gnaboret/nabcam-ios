import HaishinKit
import AVFoundation
import UniformTypeIdentifiers
import SwiftUI
import NabcamCore

private let nabPurple = Color(red: 0.64, green: 0.43, blue: 1)
private let nabGreen = Color(red: 0.05, green: 0.81, blue: 0.63)

struct BroadcastView: View {
    @StateObject private var model = BroadcastModel()
    @StateObject private var chat = KickChatService()
    @StateObject private var connections = ConnectionProfiles()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var confirmLive = false
    @State private var profileID: UUID?
    @State private var profileName = ""
    @State private var confirmDelete = false
    @State private var profileNotice: String?
    @State private var destination = ""
    @State private var bitrate = 1600
    @State private var chatChannel = ""
    @State private var importWatermark = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CapturePreview(model: model).ignoresSafeArea()
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("GNAB CAM IRL · iOS Preview").font(.headline).foregroundStyle(nabPurple)
                        Text(model.status).font(.caption).foregroundStyle(model.isLive ? nabGreen : .white)
                            .accessibilityIdentifier("capture-status")
                        if let capture = model.captureFPS, let mixed = model.mixedFPS {
                            Text(String(format: "Camera %.1f · Output %.1f FPS", capture, mixed))
                                .font(.caption.monospacedDigit()).foregroundStyle(.white)
                        }
                        if let paths = model.relayPathStatus {
                            Text(paths).font(.caption2).foregroundStyle(.white)
                        }
                    }
                    .padding(12).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                    Spacer()
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill").frame(width: 48, height: 48) }
                        .foregroundStyle(.black).background(nabPurple, in: Circle()).accessibilityLabel("Settings")
                }
                Spacer()
                if chat.isEnabled {
                    HStack {
                        ChatOverlayView(chat: chat).frame(maxWidth: 380)
                        Spacer()
                    }.frame(maxHeight: 200, alignment: .bottom).clipped()
                }
                HStack {
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
                    if model.hasTorch {
                        Button { Task { await model.toggleTorch() } } label: {
                            Image(systemName: model.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        }.accessibilityLabel(model.isTorchOn ? "Turn flashlight off" : "Turn flashlight on")
                            .disabled(!model.isReady || model.isBusy)
                    }
                    Spacer()
                    if model.isConnecting {
                        Button("CANCEL") { Task { await model.stop() } }
                    } else if model.isBusy {
                        ProgressView().tint(nabGreen)
                    } else if model.isLive {
                        Button("STOP", role: .destructive) { Task { await model.stop() } }
                    } else {
                        Button("START") { confirmLive = true }.disabled(!model.isReady)
                    }
                    Spacer()
                    Button(model.isFront ? "REAR CAMERA" : "SELFIE") { Task { await model.switchCamera() } }
                        .disabled(!model.isReady || model.isBusy || model.isLive)
                }
                .buttonStyle(.borderedProminent).tint(nabGreen).foregroundStyle(.black)
            }.padding(20)
        }
        .task { connections.load(); await model.setActive(true) }
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
                Form {
                    Section("Camera") {
                        Toggle("Mirror front camera", isOn: Binding(get: { model.mirrorFrontCamera }, set: { value in
                            Task { await model.setFrontCameraMirrored(value) }
                        })).disabled(!model.isReady || model.isBusy || model.isLive)
                        Text("Matches the selfie preview and outgoing video. Rear camera stays unmirrored. Change before going live.")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.maximumZoom > model.minimumZoom {
                            LabeledContent("Zoom", value: String(format: "%.1f×", model.zoom))
                            Slider(value: Binding(get: { model.zoom }, set: { value in Task { await model.setZoom(value) } }),
                                   in: model.minimumZoom...model.maximumZoom)
                                .accessibilityLabel("Camera zoom")
                                .disabled(!model.isReady || model.isBusy)
                            Text("Digital zoom crops the camera image; higher zoom can reduce detail.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else { Text("Zoom is unavailable on this camera.").font(.caption) }
                        if model.hasTorch {
                            Toggle("Flashlight", isOn: Binding(get: { model.isTorchOn }, set: { value in
                                if value != model.isTorchOn { Task { await model.toggleTorch() } }
                            })).disabled(!model.isReady || model.isBusy)
                        } else { Text("This camera has no flashlight.").font(.caption) }
                    }
                    Section("Connection") {
                        Menu("Saved connections") {
                            Button("New connection") {
                                profileID = nil; profileName = ""; destination = ""; profileNotice = nil
                            }
                            ForEach(connections.profiles) { profile in
                                Button(profile.name) {
                                    profileID = profile.id; profileName = profile.name
                                    destination = profile.destination; bitrate = profile.bitrateKbps
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
                        Text("Include your stream key in the URL. Save stores this connection, video mode, bitrate and chat channel securely on this iPhone. Unsaved edits stay in memory.").font(.caption).foregroundStyle(.secondary)
                        Toggle("Experimental SRTLA", isOn: Binding(get: { model.experimentalSrtlaEnabled }, set: {
                            model.setExperimentalSrtla($0)
                        })).disabled(model.isLive || model.isBusy).accessibilityIdentifier("experimental-srtla-toggle")
                        if model.experimentalSrtlaEnabled {
                            Text("Use srtla:// with an SRTLA receiver. Tries Wi-Fi plus iOS’s selected cellular connection; it cannot select both SIMs. Real-iPhone failover and A/V sync are unverified. Re-enable this test option after reopening the app.")
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
                    Section("Video") {
                        Picker("Resolution / FPS", selection: Binding(get: { model.videoPreset }, set: { preset in
                            Task { await model.configureVideo(preset) }
                        })) {
                            ForEach(VideoPreset.allCases) { Text($0.label).tag($0) }
                        }.disabled(model.isLive || model.isBusy)
                        Picker("Target bitrate", selection: $bitrate) {
                            ForEach([444, 800, 1200, 1600, 2500, 4000, 6000], id: \.self) { Text("\($0) kbps").tag($0) }
                        }.disabled(model.isLive || model.isBusy)
                        Text("This selects the requested rate. The HUD measures camera and compositor output separately—not the receiver’s FPS. Unsupported camera modes show an error. H.264 + AAC; no adaptive controller yet.").font(.caption)
                    }
                    Section("Chat") {
                        TextField("Kick channel name", text: $chatChannel)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(chat.isEnabled ? "Disconnect chat" : "Connect chat") {
                            if chat.isEnabled { chat.disconnect() }
                            else { chat.connect(channel: chatChannel) }
                        }
                        Text(chat.status).font(.caption).foregroundStyle(.secondary)
                        Text("Preview chat only—it is not embedded in the outgoing video yet. Chat disconnects when you leave the app.").font(.caption)
                    }
                    Section("Stream overlays") {
                        ForEach(Array(model.watermarks.enumerated()), id: \.element.id) { index, watermark in
                            LabeledContent("Watermark \(index + 1)", value: "PNG / JPEG")
                            Picker("Position", selection: Binding(get: { watermark.corner }, set: { corner in
                                Task { await model.configureWatermark(id: watermark.id, corner: corner) }
                            })) {
                                ForEach(ClockCorner.allCases) { Text($0.rawValue).tag($0) }
                            }.disabled(model.isLive || model.isBusy)
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
                    Section("First iOS build") {
                        Text("Calls and other microphone interruptions stop the stream. Preview resumes when available; tap Start to go live again.").font(.caption)
                        Text("SRTLA is opt-in and experimental. Dual-SIM bonding, USB cameras, browser overlays, Twitch chat, purchases and background broadcasting are not included yet. Camera switching is available before going live.").font(.caption)
                        Button("Restart camera preview") { Task { await model.restartPreview() } }
                            .disabled(model.isLive || model.isBusy)
                    }
                    Section("Diagnostics") {
                        ShareLink("Share diagnostic timeline", item: model.diagnosticReport)
                        Button("Clear diagnostic timeline", role: .destructive) { model.clearDiagnostics() }
                        Text("Last 300 events, including camera/output FPS, frame gaps and experimental SRTLA queue status. No stream keys or chat contents. Receiver audio sync and network quality are not measured.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settings-form")
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
            Button("Go live") { model.start(destination: destination, bitrateKbps: bitrate) }
        }
        .alert("GNAB CAM IRL", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func saveConnection() {
        do {
            let profile = try ConnectionProfile(id: profileID ?? UUID(), name: profileName,
                destination: destination, bitrateKbps: bitrate, chatChannel: chatChannel, videoPreset: model.videoPreset)
            if connections.save(profile) {
                profileID = profile.id; profileName = profile.name
                profileNotice = "Saved securely on this iPhone."
            } else { profileNotice = nil }
        } catch { profileNotice = error.localizedDescription }
    }
}

private struct CapturePreview: UIViewRepresentable {
    let model: BroadcastModel
    func makeUIView(context: Context) -> MTHKView {
        let view = MTHKView(frame: .zero)
        view.videoGravity = .resizeAspect
        Task { await model.mixer.addOutput(view) }
        return view
    }
    func updateUIView(_ uiView: MTHKView, context: Context) {}
}
