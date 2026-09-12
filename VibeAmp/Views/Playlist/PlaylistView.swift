import SwiftUI
import AppKit

struct PlaylistView: View {
    @Environment(QueueStore.self) private var queue
    @Environment(AppState.self) private var appState

    /// Winamp-style: a click highlights a track, a double click starts it.
    @State private var selection: Int?
    @Environment(WindowManager.self) private var windows

    var body: some View {
        RetroWindowChrome(role: .playlist) {
            VStack(spacing: 6) {
                HStack {
                    Text("\(queue.entries.count) TRACKS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(VibeTheme.textSecondary)
                    Button("PLAYLISTS") {
                        windows.show(.savedPlaylists)
                    }
                    .buttonStyle(RetroButtonStyle())
                    .help("Open saved playlists and drag tracks into them")
                    Text("DOUBLE-CLICK TO PLAY")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(VibeTheme.textSecondary.opacity(0.7))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("CLEAR") {
                        queue.clear()
                        appState.persistEphemeral()
                    }
                    .buttonStyle(RetroButtonStyle())
                    .help("Clear queue")
                    .accessibilityLabel("Clear queue")
                    .disabled(queue.entries.isEmpty)
                }
                if queue.entries.isEmpty {
                    VStack {
                        Spacer()
                        Text("QUEUE EMPTY")
                            .font(VibeTheme.lcdFont(size: 16))
                            .foregroundStyle(VibeTheme.lcdDimGreen)
                        Text("Search for music to fill it")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(VibeTheme.textSecondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .overlay(Rectangle().stroke(VibeTheme.borderDark, lineWidth: 1))
                } else {
                    QueueTracksTable(tracks: queue.entries, currentIndex: queue.currentIndex,
                                     selection: $selection,
                                     play: { appState.playIndex($0) },
                                     remove: { index in
                                         queue.remove(at: IndexSet(integer: index))
                                         appState.persistEphemeral()
                                     },
                                     move: { source, destination in
                                         queue.move(from: IndexSet(integer: source), to: destination)
                                         appState.persistEphemeral()
                                     })
                        .overlay(Rectangle().stroke(VibeTheme.borderDark, lineWidth: 1))
                }
            }
            .padding(8)
            .onChange(of: queue.entries) { _, _ in selection = nil }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

/// AppKit owns selection, double-click and drag initiation in one event system.
/// In particular, a double-click recognizer must never swallow mouseDragged.
private struct QueueTracksTable: NSViewRepresentable {
    let tracks: [Track]
    let currentIndex: Int
    @Binding var selection: Int?
    let play: (Int) -> Void
    let remove: (Int) -> Void
    let move: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = TrackTable()
        table.headerView = nil
        table.backgroundColor = .black
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("track"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.playSelected(_:))
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.registerForDraggedTypes([NSPasteboard.PasteboardType(QueueTrackDrag.typeIdentifier)])
        table.setAccessibilityLabel("Playback queue")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        table.frame = scroll.contentView.bounds
        table.autoresizingMask = [.width]
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let previous = context.coordinator.parent
        context.coordinator.parent = self
        if previous.tracks != tracks || previous.currentIndex != currentIndex || table.numberOfRows != tracks.count {
            table.reloadData()
        }
        let row = selection ?? -1
        if table.selectedRow != row {
            if tracks.indices.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            else { table.deselectAll(nil) }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: QueueTracksTable
        init(_ parent: QueueTracksTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.tracks.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.tracks.indices.contains(row) else { return nil }
            let track = parent.tracks[row]
            let cell = NSTableCellView()
            func label(_ string: String, size: CGFloat, color: Color) -> NSTextField {
                let field = NSTextField(labelWithString: string)
                field.font = .monospacedSystemFont(ofSize: size, weight: .regular)
                field.textColor = NSColor(color)
                field.lineBreakMode = .byTruncatingTail
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                return field
            }
            let number = label("\(row + 1).", size: 9, color: VibeTheme.lcdDimGreen)
            number.alignment = .right
            let title = label(track.title, size: 11,
                              color: row == parent.currentIndex ? VibeTheme.lcdGreen : VibeTheme.textPrimary)
            let uploader = label(track.uploader, size: 9, color: VibeTheme.textSecondary)
            let titleStack = NSStackView(views: [title, uploader])
            titleStack.orientation = .vertical
            titleStack.alignment = .leading
            titleStack.spacing = 1
            let duration = label(track.durationString, size: 9, color: VibeTheme.textSecondary)
            duration.alignment = .right
            let delete = NSButton(title: "×", target: self, action: #selector(removeTrack(_:)))
            delete.isBordered = false
            delete.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
            delete.contentTintColor = NSColor(VibeTheme.textSecondary)
            delete.tag = row
            delete.toolTip = "Remove \(track.title)"
            delete.setAccessibilityLabel("Remove \(track.title)")
            let stack = NSStackView(views: [number, titleStack, duration, delete])
            stack.spacing = 6
            stack.alignment = .centerY
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                number.widthAnchor.constraint(equalToConstant: 20),
                duration.widthAnchor.constraint(equalToConstant: 48),
                delete.widthAnchor.constraint(equalToConstant: 18),
                title.widthAnchor.constraint(equalTo: titleStack.widthAnchor),
                uploader.widthAnchor.constraint(equalTo: titleStack.widthAnchor)
            ])
            cell.textField = title
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = TrackRow()
            view.playing = row == parent.currentIndex
            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            parent.selection = table.selectedRow >= 0 ? table.selectedRow : nil
        }

        @objc func playSelected(_ table: NSTableView) {
            guard parent.tracks.indices.contains(table.selectedRow) else { return }
            parent.play(table.selectedRow)
        }

        @objc func removeTrack(_ button: NSButton) {
            guard parent.tracks.indices.contains(button.tag) else { return }
            parent.remove(button.tag)
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.tracks.indices.contains(row) else { return nil }
            return QueueTrackDrag(track: parent.tracks[row], sourceIndex: row).pasteboardItem()
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard let source = info.draggingSource as? NSTableView, source === tableView else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let source = info.draggingSource as? NSTableView, source === tableView,
                  let data = info.draggingPasteboard.data(forType: NSPasteboard.PasteboardType(QueueTrackDrag.typeIdentifier)),
                  let payload = try? JSONDecoder().decode(QueueTrackDrag.self, from: data),
                  parent.tracks.indices.contains(payload.sourceIndex),
                  parent.tracks[payload.sourceIndex] == payload.track else { return false }
            parent.move(payload.sourceIndex, row)
            return true
        }
    }

    final class TrackTable: NSTableView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36, let doubleAction {
                NSApp.sendAction(doubleAction, to: target, from: self)
            } else { super.keyDown(with: event) }
        }
    }

    final class TrackRow: NSTableRowView {
        var playing = false
        override var interiorBackgroundStyle: NSView.BackgroundStyle { .dark }
        override func drawBackground(in dirtyRect: NSRect) {
            (playing ? NSColor(VibeTheme.lcdDimGreen).withAlphaComponent(0.35) : .black).setFill()
            bounds.fill()
        }
        override func drawSelection(in dirtyRect: NSRect) {
            NSColor(VibeTheme.panelRaised).setFill()
            bounds.fill()
            NSColor(VibeTheme.lcdGreen).setStroke()
            NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }
}
