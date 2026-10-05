import HaishinKit
import SwiftUI

private let nabPurple = Color(red: 0.64, green: 0.43, blue: 1)
private let nabGreen = Color(red: 0.05, green: 0.81, blue: 0.63)

struct BroadcastView: View {
    @StateObject private var model = BroadcastModel()
    @StateObject private var chat = KickChatService()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var confirmLive = false
    // Credentials stay in memory until a Keychain-backed profile store is added.
    @State private var destination = ""
    @State private var bitrate = 1600
    @State private var chatChannel = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CapturePreview(model: model).ignoresSafeArea()
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NABCAM IRL · iOS Preview").font(.headline).foregroundStyle(nabPurple)
                        Text(model.status).font(.caption).foregroundStyle(model.isLive ? nabGreen : .white)
                    }
                    .padding(12).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                    Spacer()
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill").frame(width: 48, height: 48) }
                        .background(nabPurple, in: Circle()).accessibilityLabel("Settings")
                }
                Spacer()
                if chat.isEnabled {
                    HStack {
                        ChatOverlayView(chat: chat).frame(maxWidth: 380)
                        Spacer()
                    }.frame(maxHeight: 200, alignment: .bottom).clipped()
                }
                HStack {
                    Button(model.isMuted ? "MIC OFF" : "MIC ON") { Task { await model.toggleMute() } }
                        .disabled(!model.isReady || model.isBusy)
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
        .task { await model.setActive(true) }
        .onChange(of: scenePhase) { phase in
            if phase == .background { chat.disconnect(); Task { await model.setActive(false) } }
            else if phase == .active { Task { await model.setActive(true) } }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form {
                    Section("Connection") {
                        SecureField("Full RTMP / RTMPS / SRT URL", text: $destination)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(model.isLive || model.isBusy)
                        Text("Include the RTMP stream key in the URL. SRT query options are passed through unchanged. URLs are kept only until you close the app.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Video") {
                        Picker("Target bitrate", selection: $bitrate) {
                            ForEach([444, 800, 1200, 1600, 2500, 4000, 6000], id: \.self) { Text("\($0) kbps").tag($0) }
                        }.disabled(model.isLive || model.isBusy)
                        Text("720p · requested 30 FPS · H.264 + AAC. Fixed bitrate target; no adaptive controller yet.").font(.caption)
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
                    Section("First iOS build") {
                        Text("Plain SRT is not SRTLA. Bonding, USB cameras, stream overlays, Twitch chat, purchases and background broadcasting are not included yet. Camera switching is available before going live.").font(.caption)
                        Button("Restart camera preview") { Task { await model.setActive(false); await model.setActive(true) } }
                            .disabled(model.isLive || model.isBusy)
                    }
                }
                .navigationTitle("Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
            }.tint(nabPurple)
        }
        .confirmationDialog("Start broadcasting camera and microphone?", isPresented: $confirmLive, titleVisibility: .visible) {
            Button("Go live") { model.start(destination: destination, bitrateKbps: bitrate) }
        }
        .alert("NABCAM IRL", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
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
