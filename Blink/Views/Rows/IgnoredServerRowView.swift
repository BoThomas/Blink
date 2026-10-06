import SwiftUI

struct IgnoredServerRowView: View {
    @Environment(AppState.self) private var appState
    let server: DevServer

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            ColorBar(color: server.framework.color.opacity(0.4))

            VStack(alignment: .leading, spacing: 2) {
                Text(server.projectName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(verbatim: ":\(server.port)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.7))

                    Text(server.framework == .unknown ? server.command : server.framework.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }

            Spacer()

            if isHovered {
                RowAction(symbol: "eye", help: "Unignore server") {
                    appState.unignoreServer(server)
                }
                .transition(.opacity)
            }
        }
        .hoverRow { isHovered = $0 }
        .onTapGesture {
            appState.openInBrowser(server)
        }
    }
}
