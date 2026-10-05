import SwiftUI

struct AcknowledgmentsView: View {
    private static let notices: String = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The bundled license notices could not be loaded. Please report this packaging error before distributing this build."
        }
        return text
    }()

    var body: some View {
        ScrollView {
            Text(Self.notices)
                .font(.footnote)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityIdentifier("third-party-notices")
        }
        .navigationTitle("Open-source acknowledgments")
        .navigationBarTitleDisplayMode(.inline)
    }
}
