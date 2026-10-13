import SwiftUI

/// What one Quick Share card shows, from the question ("accept?") to the result.
@MainActor
final class ShareCard: ObservableObject {
    enum Phase: Equatable {
        case asking
        case receiving
        case done(ShareResult)
    }

    let share: IncomingShare
    @Published var phase = Phase.asking
    @Published var receivedBytes: Int64 = 0

    var onAnswer: (Bool) -> Void = { _ in }
    var onStop: () -> Void = {}
    var onClose: () -> Void = {}

    init(share: IncomingShare, phase: Phase = .asking, receivedBytes: Int64 = 0) {
        self.share = share
        self.phase = phase
        self.receivedBytes = receivedBytes
    }

    // MARK: The words on the card

    var title: String {
        switch phase {
        case .asking:
            return "“\(share.sender)” wants to send you \(what)"
        case .receiving:
            return "Receiving \(what) from “\(share.sender)”…"
        case .done(.saved(let files)):
            return files.count == 1 ? "Saved to Downloads" : "\(files.count) files saved to Downloads"
        case .done(.text):             return "Text copied"
        case .done(.link):             return "Link copied"
        case .done(.cancelledByPhone): return "Cancelled on the phone"
        case .done(.missed):           return "You missed a share from “\(share.sender)”"
        case .done(.failed):           return "The transfer didn’t finish"
        case .done(.declined), .done(.stopped):
            return "Stopped"
        }
    }

    var detail: String {
        switch phase {
        case .asking, .receiving:
            return offerLine
        case .done(.saved(let files)):
            return Self.list(files.map(\.lastPathComponent))
        case .done(.text(let text)):
            return "It is on the clipboard: paste it anywhere with ⌘V.\n" + Self.preview(text)
        case .done(.link(let link)):
            return "It is on the clipboard.\n" + Self.preview(link)
        case .done(.cancelledByPhone):
            return "Nothing was saved."
        case .done(.missed):
            return "Nobody answered in time, so nothing was saved. Send it again from the phone."
        case .done(.failed(let reason)):
            return "What happened: \(reason). Anything that arrived only in part was removed."
        case .done(.declined), .done(.stopped):
            return "Anything that arrived only in part was removed."
        }
    }

    /// "a file", "3 files", "some text" or "a link".
    private var what: String {
        switch share.contents {
        case .files(let files): return files.count == 1 ? "a file" : "\(files.count) files"
        case .text:             return "some text"
        case .link:             return "a link"
        }
    }

    /// "photo.jpg, notes.pdf and 2 more · 4.2 MB"
    private var offerLine: String {
        switch share.contents {
        case .files(let files):
            return Self.list(files.map(\.name)) + " · " + Self.size(share.totalBytes)
        case .text(let title), .link(let title):
            return title.isEmpty ? "The text itself arrives after you accept." : title
        }
    }

    var progressLine: String {
        "\(Self.size(receivedBytes)) of \(Self.size(share.totalBytes))"
    }

    var fraction: Double {
        share.totalBytes > 0 ? min(1, Double(receivedBytes) / Double(share.totalBytes)) : 0
    }

    /// The link to offer an "Open Link" button for: web links only.
    var openableLink: URL? {
        guard case .done(.link(let text)) = phase,
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    var savedFiles: [URL] {
        guard case .done(.saved(let files)) = phase else { return [] }
        return files
    }

    var symbol: String {
        switch phase {
        case .asking, .receiving:
            switch share.contents {
            case .files: return "arrow.down.doc"
            case .text:  return "text.quote"
            case .link:  return "link"
            }
        case .done(.saved), .done(.text), .done(.link):
            return "checkmark.circle.fill"
        case .done(.failed):
            return "exclamationmark.triangle.fill"
        default:
            return "xmark.circle"
        }
    }

    static func list(_ names: [String]) -> String {
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) and \(names.count - 2) more" : shown
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func preview(_ text: String) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return oneLine.count > 140 ? String(oneLine.prefix(140)) + "…" : oneLine
    }
}

/// One card: who is sending what, the code to compare, and the buttons.
struct ShareCardView: View {
    @ObservedObject var card: ShareCard

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: card.symbol)
                .font(.system(size: 28))
                .foregroundStyle(tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 8) {
                Text(card.title).font(.headline)
                Text(card.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .truncationMode(.middle)

                if card.phase == .asking {
                    Text("Code \(card.share.code). If your phone shows a code, it should be the same one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if card.phase == .receiving {
                    ProgressView(value: card.fraction)
                    Text(card.progressLine).font(.callout).foregroundStyle(.secondary)
                }
                buttons.padding(.top, 4)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 440, alignment: .leading)
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            Spacer()
            switch card.phase {
            case .asking:
                Button("Decline") { card.onAnswer(false) }
                // Deliberately not the default button: a stray press of Return must never
                // accept a file.
                Button("Accept") { card.onAnswer(true) }
            case .receiving:
                Button("Stop") { card.onStop() }
            case .done:
                if !card.savedFiles.isEmpty {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(card.savedFiles)
                        card.onClose()
                    }
                }
                if let link = card.openableLink {
                    Button("Open Link") {
                        NSWorkspace.shared.open(link)
                        card.onClose()
                    }
                }
                Button("Close") { card.onClose() }
            }
        }
    }

    private var tint: Color {
        switch card.phase {
        case .done(.saved), .done(.text), .done(.link): return .green
        case .done(.failed):                            return .orange
        case .done:                                     return .secondary
        default:                                        return .accentColor
        }
    }
}

/// Shows the cards. Each one floats in the top-right corner of the screen and does NOT
/// take the keyboard away from the app you are working in.
@MainActor
final class QuickSharePrompts {
    static let shared = QuickSharePrompts()

    private var cards: [UUID: (card: ShareCard, panel: NSPanel)] = [:]

    func ask(_ share: IncomingShare, answer: @escaping (Bool) -> Void, stop: @escaping () -> Void) {
        let card = ShareCard(share: share)
        card.onAnswer = { [weak self, weak card] accepted in
            answer(accepted)
            guard accepted else {
                self?.close(share.id)
                return
            }
            card?.phase = .receiving
            self?.fit(share.id)
        }
        card.onStop = { [weak self] in
            stop()
            self?.close(share.id)
        }
        card.onClose = { [weak self] in self?.close(share.id) }

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Quick Share"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ShareCardView(card: card))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        cards[share.id] = (card, panel)
        arrange()
        panel.orderFrontRegardless()
    }

    func progress(_ id: UUID, bytes: Int64) {
        cards[id]?.card.receivedBytes = bytes
    }

    func finished(_ id: UUID, _ result: ShareResult) {
        guard let card = cards[id]?.card else { return }
        switch result {
        case .declined, .stopped:
            return close(id) // the person did this themselves: nothing to tell them
        case .text(let text), .link(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        default:
            break
        }
        card.phase = .done(result)
        fit(id)
        // A result doesn't need to stay on screen forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.close(id) }
    }

    /// The card's height changes with what it shows.
    private func fit(_ id: UUID) {
        guard let panel = cards[id]?.panel, let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(host.fittingSize)
        arrange()
    }

    private func close(_ id: UUID) {
        guard let (_, panel) = cards.removeValue(forKey: id) else { return }
        panel.close()
        arrange()
    }

    /// Stacks the cards under the menu bar, on the right.
    private func arrange() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var top = screen.maxY - 12
        for (_, panel) in cards.values.sorted(by: { $0.panel.windowNumber < $1.panel.windowNumber }) {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 12, y: top - size.height))
            top -= size.height + 10
        }
    }
}
