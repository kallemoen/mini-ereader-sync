import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct MenuView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            articleList
            Divider()
            footer
        }
        .frame(width: 380, height: 520)
        .onAppear {
            state.wifi.setFastScanning(true)
        }
        .onDisappear {
            state.wifi.setFastScanning(false)
        }
    }

    private func openSettings() {
        AppDelegate.shared?.showSettings()
    }

    private func runImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType("org.idpf.epub-container"), UTType(filenameExtension: "epub")]
            .compactMap { $0 }
        panel.prompt = "Import"
        panel.message = "Select EPUB files to add to your library."
        // Activate so the panel comes to the front from an accessory app, then
        // run modally — sheet mode isn't an option from a MenuBarExtra popover.
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            state.importManualEPUBs(panel.urls)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(state.newCount) new")
                    .font(.title2).bold()
                Text("\(state.readyCount) ready to sync")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ConnectionPill(wifi: state.wifi)
        }
        .padding(12)
    }

    private var articleList: some View {
        Group {
            if state.articles.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(state.needsSettings
                         ? "No articles yet.\nUse Import… to add EPUBs, or set up Instapaper in Settings."
                         : "No articles yet.\nSave something to Instapaper, or use Import…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(state.articles) { article in
                            ArticleRow(
                                article: article,
                                onReconvert: { state.reconvert(article) },
                                onResync: { state.resync(article) },
                                onDeleteLocally: { state.deleteLocally(article) }
                            )
                            .padding(.horizontal, 12)
                            Divider().padding(.leading, 12)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let msg = state.lastSyncResult {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let err = state.lastPollError {
                Text("Poll error: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            SyncButton(state: state, wifi: state.wifi)
            HStack {
                Button("Refresh") {
                    Task { await state.pollNow() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Button("Import…") { runImportPanel() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Spacer()
                Button("Settings") { openSettings() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(12)
    }
}
