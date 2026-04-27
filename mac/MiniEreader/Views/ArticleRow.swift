import SwiftUI
import AppKit

struct ArticleRow: View {
    let article: Article
    let onReconvert: () -> Void
    let onResync: () -> Void
    let onDeleteLocally: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .font(.callout)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(sourceLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if article.removedFromSource {
                        Text("· removed from Instapaper")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if let msg = article.errorMessage, article.status == .error {
                        Text("· \(msg)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            actions
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if fileExists {
                Button(action: revealInFinder) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal EPUB in Finder")
            }
            Menu {
                if article.status == .synced {
                    Button("Re-sync to reader", action: onResync)
                }
                if !article.isManual {
                    Button("Re-convert from source", action: onReconvert)
                }
                if canDeleteLocally {
                    Divider()
                    Button("Delete locally", role: .destructive, action: onDeleteLocally)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.caption)
    }

    private var fileExists: Bool {
        if let path = article.epubPath, FileManager.default.fileExists(atPath: path) {
            return true
        }
        return FileCache.exists(for: article.id)
    }

    private func revealInFinder() {
        let url = article.epubPath.map { URL(fileURLWithPath: $0) }
            ?? FileCache.epubURL(for: article.id)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var sourceLabel: String {
        article.isManual ? "local file" : article.hostname
    }

    private var canDeleteLocally: Bool {
        article.isManual || article.removedFromSource
    }

    private var dotColor: Color {
        if article.removedFromSource { return .orange }
        switch article.status {
        case .new: return .blue
        case .converting: return .yellow
        case .converted: return .green
        case .synced: return .gray
        case .error: return .red
        }
    }
}
