import SwiftUI
import NabcamCore

struct BrowserSourceSettings: View {
    @ObservedObject var store: BrowserOverlaySources
    let locked: Bool
    let apply: () async -> Void

    var body: some View {
        Section("Browser sources · experimental") {
            ForEach(store.sources) { source in
                NavigationLink("Browser source \(source.id) · \(source.enabled ? "On" : "Off")") {
                    BrowserSourceEditor(store: store, source: source, apply: apply)
                }.accessibilityIdentifier("browser-source-\(source.id)")
                    .disabled(locked || !store.canWrite)
            }
            Button("Add browser source") { _ = store.add() }
                .disabled(locked || !store.canWrite || store.sources.count >= 3)
            SettingsHelp(title: "Browser source limits", detail: "Up to 3 HTTPS widgets. Visuals only—browser audio, logins and interactive pages are not supported. Change before going live. Performance needs device testing.")
            if let message = store.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
                Button("Retry loading browser sources") { store.load() }.disabled(locked)
            }
        }
    }
}

private struct BrowserSourceEditor: View {
    @ObservedObject var store: BrowserOverlaySources
    @State var source: BrowserOverlayConfiguration
    let apply: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var applying = false
    @State private var invalid = false

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $source.enabled)
                    .accessibilityIdentifier("browser-source-enabled")
                SecureField("HTTPS widget URL", text: $source.url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("browser-source-url")
                SettingsHelp(title: "URL privacy", detail: "Widget URLs can contain private tokens. Saved in Keychain, not diagnostics.")
                Picker("Show in", selection: $source.destination) {
                    ForEach(BrowserOverlayDestination.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("Position", selection: $source.position) {
                    ForEach(BrowserOverlayPosition.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper("Size: \(source.sizePercent)%", value: $source.sizePercent, in: 10...100, step: 5)
                Stepper("Edge padding: \(source.paddingPercent)%", value: $source.paddingPercent, in: 0...10)
                Stepper("Opacity: \(source.opacityPercent)%", value: $source.opacityPercent, in: 0...100, step: 5)
            }
            Section("Webpage viewport") {
                LabeledContent("Width") {
                    TextField("Width", value: $source.contentWidth, format: .number).keyboardType(.numberPad)
                }
                LabeledContent("Height") {
                    TextField("Height", value: $source.contentHeight, format: .number).keyboardType(.numberPad)
                }
                SettingsHelp(title: "Viewport size help", detail: "1–4096 pixels per side. Controls webpage layout, not overlay size. Snapshots use at most 640 pixels per side and 5 updates per second.")
            }
            if invalid { Text("Use a valid HTTPS URL and viewport dimensions from 1 to 4096.").foregroundStyle(.red) }
            if let message = store.errorMessage { Text(message).foregroundStyle(.red) }
            Button(applying ? "Applying…" : "Apply / Reload") {
                guard (try? source.validated()) != nil else { invalid = true; return }
                invalid = false
                guard store.save(source) else { return }
                applying = true
                Task { await apply(); applying = false; dismiss() }
            }
            if source.id != 1 {
                Button("Remove source", role: .destructive) {
                    guard store.remove(id: source.id) else { return }
                    applying = true
                    Task { await apply(); applying = false; dismiss() }
                }
            }
        }
        .disabled(applying)
        .navigationTitle("Browser source \(source.id)")
    }
}
