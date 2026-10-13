import SwiftUI
import UniformTypeIdentifiers

/// Opens the "Phone Files" window. It is created the first time it is needed.
@MainActor
final class FilesWindowController: NSObject, NSWindowDelegate {
    static let shared = FilesWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = FilesWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                     backing: .buffered, defer: false)
            window.title = "Phone Files"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: FilesView().environmentObject(FileBrowser.shared))
            window.setContentSize(NSSize(width: 660, height: 480))
            window.center()
            window.delegate = self
            self.window = window
        }
        NSApp.activate()
        if window?.isKeyWindow == true { FileBrowser.shared.reload() }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Coming back to the window (say, after taking a screenshot on the phone) reads the
    /// folder again, so the newest files are there.
    func windowDidBecomeKey(_ notification: Notification) {
        FileBrowser.shared.reload()
    }
}

/// The app has no menu bar of its own, so ⌘W is handled here.
final class FilesWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The window's contents: where you are, the file list, and the copy status.
struct FilesView: View {
    @EnvironmentObject private var browser: FileBrowser

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ZStack {
                FileTable(browser: browser)
                if let notice = browser.notice {
                    Text(notice)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(24)
                        .allowsHitTesting(false)
                } else if browser.isLoading && browser.files.isEmpty {
                    ProgressView()
                }
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 560, minHeight: 320)
        .overlay {
            if browser.isDropTarget {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 3).allowsHitTesting(false)
            }
        }
        // Catches drops that miss the list (for example on an empty folder's message).
        .onDrop(of: [.fileURL], isTargeted: $browser.isDropTarget, perform: receive)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { browser.goUp() } label: { Image(systemName: "chevron.left") }
                .disabled(!browser.canGoUp)
                .help("Go to the folder that contains this one")
            Menu {
                ForEach(PhoneFolder.places, id: \.title) { place in
                    Button(place.title) { browser.open(place.folder) }
                }
            } label: {
                Label(browser.folder.title, systemImage: "folder")
            }
            .fixedSize()
            .help("Jump to a folder on your phone")
            Text(browser.folder.breadcrumb)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            if !browser.linkLine.isEmpty {
                Text(browser.linkLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                .keyboardShortcut("r")
                .help("Read this folder again (⌘R)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if let activity = browser.activity {
                ProgressView().controlSize(.small)
                Text(activity)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(browser.resultLine
                     ?? "Drag files in to send them to your phone, or out to copy them to your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if browser.failureDetails != nil {
                    Button("Details…") { browser.showFailureDetails() }
                }
            }
            Spacer(minLength: 8)
            if browser.activity != nil {
                Button("Stop") { browser.cancelTransfers() }
            }
            Button("Send Files…") { browser.chooseFilesToSend(from: NSApp.keyWindow) }
                .disabled(!browser.isConnected)
            Button("Save to Downloads") { browser.saveSelectionToDownloads() }
                .disabled(browser.selectedNames.isEmpty)
                .help("Copy the selected files to this Mac’s Downloads folder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Files dropped on the window: collect their locations, then copy them to the
    /// folder that is on screen.
    private func receive(_ providers: [NSItemProvider]) -> Bool {
        let wanted = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !wanted.isEmpty else { return false }

        let browser = browser
        let collected = DroppedURLs()
        let allLoaded = DispatchGroup()
        for provider in wanted {
            allLoaded.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.add(url) }
                allLoaded.leave()
            }
        }
        allLoaded.notify(queue: .main) {
            MainActor.assumeIsolated { browser.send(collected.all) }
        }
        return true
    }
}

/// Collects dropped file locations, which arrive on background threads.
private final class DroppedURLs: @unchecked Sendable {
    private var urls: [URL] = []
    private let lock = NSLock()
    func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

// MARK: - The file list

/// The file list is an AppKit table (inside the SwiftUI window), because AppKit can
/// "promise" a file: a dragged row is only copied from the phone once it is dropped.
struct FileTable: NSViewRepresentable {
    @ObservedObject var browser: FileBrowser

    func makeCoordinator() -> Coordinator {
        Coordinator(browser: browser)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .fullWidth
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        table.addTableColumn(Self.column("name", "Name", width: 330, minWidth: 160, ascendingFirst: true))
        table.addTableColumn(Self.column("size", "Size", width: 90, minWidth: 70, ascendingFirst: false))
        table.addTableColumn(Self.column("date", "Date Modified", width: 190, minWidth: 130, ascendingFirst: false))
        table.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)] // newest first

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClickedRow)

        // Dragging in: files from Finder. Dragging out: copies only, to other apps only.
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([], forLocal: true)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.show(browser.files, in: browser.folder)
    }

    private static func column(_ id: String, _ title: String, width: CGFloat, minWidth: CGFloat,
                               ascendingFirst: Bool) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: ascendingFirst)
        return column
    }

    /// Feeds the table, and handles double-clicks, sorting and drag and drop.
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private let browser: FileBrowser
        private let writer: PromiseWriter
        weak var table: NSTableView?

        private var received: [PhoneFile] = []   // as the browser gave them
        private var folder = PhoneFolder()
        private var rows: [PhoneFile] = []       // in the order on screen
        private var icons: [String: NSImage] = [:]

        init(browser: FileBrowser) {
            self.browser = browser
            self.writer = PromiseWriter(transfers: browser.transfers)
        }

        // MARK: Rows

        /// Called on every window update; only does work when the files really changed.
        func show(_ files: [PhoneFile], in newFolder: PhoneFolder) {
            guard let table, files != received || newFolder != folder else { return }
            // Keep the selection when the same folder is read again.
            let selected = newFolder == folder ? selectedNames(in: table) : []
            received = files
            folder = newFolder
            rows = sorted(files)
            table.reloadData()
            let keep = IndexSet(rows.indices.filter { selected.contains(rows[$0].name) })
            table.selectRowIndexes(keep, byExtendingSelection: false)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        /// Folders first, then by the clicked column.
        private func sorted(_ files: [PhoneFile]) -> [PhoneFile] {
            let order = table?.sortDescriptors.first
            let ascending = order?.ascending ?? false
            let byName: (PhoneFile, PhoneFile) -> ComparisonResult = { $0.name.localizedStandardCompare($1.name) }

            return files.sorted { first, second in
                if first.isFolder != second.isFolder { return first.isFolder }
                var result: ComparisonResult
                switch order?.key {
                case "name": result = byName(first, second)
                case "size": result = first.size == second.size ? .orderedSame
                                    : (first.size < second.size ? .orderedAscending : .orderedDescending)
                default:     result = first.modified.compare(second.modified)
                }
                if result == .orderedSame { return byName(first, second) == .orderedAscending }
                return ascending ? result == .orderedAscending : result == .orderedDescending
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let selected = selectedNames(in: tableView)
            rows = sorted(received)
            tableView.reloadData()
            let keep = IndexSet(rows.indices.filter { selected.contains(rows[$0].name) })
            tableView.selectRowIndexes(keep, byExtendingSelection: false)
        }

        // MARK: Cells

        private static let sizeText: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()

        private static let dateText: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            formatter.doesRelativeDateFormatting = true // "Today at 9:41 AM"
            return formatter
        }()

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, rows.indices.contains(row) else { return nil }
            let file = rows[row]
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? Self.makeCell(id)

            switch id.rawValue {
            case "name":
                cell.textField?.stringValue = file.name
                cell.imageView?.image = icon(for: file)
            case "size":
                cell.textField?.stringValue = file.isFolder ? "—" : Self.sizeText.string(fromByteCount: file.size)
            default:
                cell.textField?.stringValue = Self.dateText.string(from: file.modified)
            }
            return cell
        }

        private static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id

            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(text)
            cell.textField = text

            var textStart = cell.leadingAnchor
            if id.rawValue == "name" {
                text.lineBreakMode = .byTruncatingMiddle
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 18),
                    image.heightAnchor.constraint(equalToConstant: 18),
                ])
                textStart = image.trailingAnchor
            } else {
                text.lineBreakMode = .byTruncatingTail
                text.textColor = .secondaryLabelColor
                if id.rawValue == "size" { text.alignment = .right }
            }
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: textStart, constant: id.rawValue == "name" ? 6 : 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        /// The Mac's own icon for this kind of file (one per file ending, remembered).
        private func icon(for file: PhoneFile) -> NSImage {
            let ending = file.isFolder ? "/" : (file.name as NSString).pathExtension.lowercased()
            if let known = icons[ending] { return known }
            let type = file.isFolder ? UTType.folder : (UTType(filenameExtension: ending) ?? .data)
            let image = NSWorkspace.shared.icon(for: type)
            icons[ending] = image
            return image
        }

        /// Lets you type the first letters of a name to jump to it.
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            rows.indices.contains(row) ? rows[row].name : nil
        }

        // MARK: Selection and double-click

        private func selectedNames(in tableView: NSTableView) -> Set<String> {
            Set(tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].name : nil })
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table else { return }
            let names = selectedNames(in: table)
            // A moment later, because this can also fire while the window is being updated.
            DispatchQueue.main.async { [browser] in
                if browser.selectedNames != names { browser.selectedNames = names }
            }
        }

        /// Double-click a folder to look inside.
        @objc func openClickedRow() {
            guard let row = table?.clickedRow, rows.indices.contains(row), rows[row].isFolder else { return }
            browser.open(folder.child(rows[row].name))
        }

        // MARK: Dragging out (phone → Mac)

        /// Each dragged row carries a promise; the copy starts when it is dropped.
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard rows.indices.contains(row), let promised = browser.promise(for: rows[row]) else { return nil }
            let file = rows[row]
            let ending = (file.name as NSString).pathExtension
            let type = file.isFolder ? UTType.folder : (UTType(filenameExtension: ending) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: writer)
            provider.userInfo = promised
            return provider
        }

        // MARK: Dragging in (Mac → phone)

        private static let fileURLsOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            // Rows of this list can't be dropped back onto it.
            if (info.draggingSource as AnyObject?) === tableView { return [] }
            guard browser.isConnected,
                  info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLsOnly) else { return [] }

            // On a folder: copy into that folder. Anywhere else: into the folder on screen.
            let ontoFolder = dropOperation == .on && rows.indices.contains(row) && rows[row].isFolder
            if !ontoFolder { tableView.setDropRow(-1, dropOperation: .on) }
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let dropped = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: Self.fileURLsOnly)
            guard let urls = dropped as? [URL], !urls.isEmpty else { return false }
            let ontoFolder = dropOperation == .on && rows.indices.contains(row) && rows[row].isFolder
            browser.send(urls, to: ontoFolder ? folder.child(rows[row].name) : folder)
            return true
        }
    }
}

/// Fulfils the promise made for a dragged row: when it is dropped (in Finder, on the
/// Desktop, in another app), the file is copied from the phone to that place.
/// AppKit calls it on a background queue, so nothing here touches the window.
final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let transfers: FileTransfers

    init(transfers: FileTransfers) {
        self.transfers = transfers
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                         fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? PromisedFile)?.item.name ?? "Phone file"
    }

    /// Copies wait their turn on the same queue as every other copy.
    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        transfers.queue
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        guard let promised = filePromiseProvider.userInfo as? PromisedFile else {
            return completionHandler(CocoaError(.fileNoSuchFile))
        }
        completionHandler(promised.transfers.writePromised(promised.item, to: url,
                                                           using: promised.adb, serial: promised.serial))
    }
}
