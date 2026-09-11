import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class PromiseWriter: NSObject, NSFilePromiseProviderDelegate {
    let entry: Entry
    let connection: Connection
    let model: BrowserModel
    let originTabID: UUID?
    init(entry: Entry, connection: Connection, model: BrowserModel, originTabID: UUID? = nil) { self.entry = entry; self.connection = connection; self.model = model; self.originTabID = originTabID }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { entry.name }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        Task { @MainActor in model.promiseDownload(entry, connection: connection, to: url, originTabID: originTabID, completion: completionHandler) }
    }
}
enum RetainedPromise {
    static func make(type: String, writer: PromiseWriter) -> NSFilePromiseProvider {
        let provider = NSFilePromiseProvider(fileType: type, delegate: writer)
        provider.userInfo = writer
        return provider
    }
}
final class CommanderTable: NSTableView {
    var activate: (() -> Void)?
    var command: ((FileCommand) -> Void)?
    var togglePanel: (() -> Void)?
    var canCommand: ((FileCommand) -> Bool)?
    @objc func copy(_ sender: Any?) { activate?(); command?(.clipboardCopy) }
    @objc func paste(_ sender: Any?) { activate?(); command?(.paste) }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return canCommand?(.clipboardCopy) ?? false }
        if item.action == #selector(paste(_:)) { return canCommand?(.paste) ?? false }
        return super.validateUserInterfaceItem(item)
    }
    var contextMenu: ((Bool) -> NSMenu)?
    var commanderKeys = true
    override func becomeFirstResponder() -> Bool { let value = super.becomeFirstResponder(); if value { activate?() }; return value }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 { togglePanel?(); return }
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "c" { activate?(); command?(.clipboardCopy); return }
            if event.charactersIgnoringModifiers == "v" { activate?(); command?(.paste); return }
            if event.charactersIgnoringModifiers == "i" { activate?(); command?(.properties); return }
            if event.keyCode == 51 { activate?(); command?(.delete); return }
        }
        if event.keyCode == 36 { activate?(); command?(.rename); return }
        if commanderKeys {
            let keys: [UInt16: FileCommand] = [99:.preview,118:.edit,96:.copy,97:.move,98:.mkdir,100:.delete]
            if let operation = keys[event.keyCode] { activate?(); command?(operation); return }
        }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        window?.makeFirstResponder(self); activate?(); return contextMenu?(row < 0)
    }
}
struct FileTable: NSViewRepresentable {
    @ObservedObject var model: BrowserModel
    @ObservedObject var tab: TabBrowser
    let remote: Bool
    var entries: [Entry] { tab.visible(remote: remote, hidden: model.showHidden) }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(), table = CommanderTable()
        table.style = .fullWidth; table.rowHeight = 27; table.intercellSpacing = NSSize(width: 10, height: 0)
        table.usesAlternatingRowBackgroundColors = true; table.allowsMultipleSelection = true; table.allowsColumnReordering = true
        for (id, title, width) in [("name","名稱",190.0),("size","大小",65.0),("modified","修改日期",125.0),("permissions","權限",50.0),("owner","UID:GID",70.0),("kind","種類",75.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); col.title = title; col.width = width; col.minWidth = id == "name" ? 140 : 45
            if ["name","size","modified","kind"].contains(id) { col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true) }
            col.isHidden = ["owner", "kind"].contains(id)
            table.addTableColumn(col)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autosaveName = remote ? "MinaSCP.RemoteColumns.v3" : "MinaSCP.LocalColumns.v3"; table.autosaveTableColumns = true
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.open)
        table.activate = { [weak coordinator = context.coordinator] in coordinator?.activate() }
        table.command = { [weak coordinator = context.coordinator] command in guard let coordinator else { return }; coordinator.parent.model.execute(command, tab: coordinator.parent.tab) }
        table.togglePanel = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            coordinator.parent.tab.state.activeSide = coordinator.parent.remote ? .local : .remote
            NotificationCenter.default.post(name: .init("MinaSCP.FocusPanel"), object: nil)
        }
        table.canCommand = { [weak coordinator = context.coordinator] command in
            guard let coordinator else { return false }
            return CommandContext(tab: coordinator.parent.tab, side: coordinator.parent.remote ? .remote : .local).allows(command)
        }
        table.contextMenu = { [weak coordinator = context.coordinator] background in
            guard let coordinator else { return NSMenu() }
            let model = coordinator.parent.model, tab = coordinator.parent.tab
            let captured = CommandContext(tab: tab, background: background)
            let menu = FileMenus.make(captured, commanderKeys: model.preferences.commanderKeys, action: { model.execute($0, context: captured) }, navigate: { path in
                guard captured.valid else { return }; Task { await tab.navigate(path, side: captured.side) }
            })
            model.commands.appendMenu(to: menu, context: captured)
            return menu
        }
        let columns = NSMenu()
        for column in table.tableColumns where column.identifier.rawValue != "name" {
            let item = NSMenuItem(title: column.title, action: #selector(Coordinator.toggleColumn(_:)), keyEquivalent: "")
            item.target = context.coordinator; item.representedObject = column.identifier.rawValue; item.state = column.isHidden ? .off : .on; columns.addItem(item)
        }
        table.headerView?.menu = columns
        table.registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        table.setDraggingSourceOperationMask(.copy, forLocal: false); table.setDraggingSourceOperationMask(.copy, forLocal: true)
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        context.coordinator.table = table
        context.coordinator.focusObserver = NotificationCenter.default.addObserver(forName: .init("MinaSCP.FocusPanel"), object: nil, queue: .main) { [weak coordinator = context.coordinator] _ in
            Task { @MainActor in guard let coordinator, coordinator.parent.tab.state.activeSide == (coordinator.parent.remote ? .remote : .local) else { return }; coordinator.table?.window?.makeFirstResponder(coordinator.table) }
        }
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let c = context.coordinator; c.parent = self; c.table?.commanderKeys = model.preferences.commanderKeys
        let selected = remote ? tab.state.remote.selection : tab.state.local.selection
        if c.rows != entries { c.rows = entries; c.reloading = true; c.table?.reloadData(); c.reloading = false }
        let indexes = IndexSet(c.rows.indices.filter { selected.contains(c.rows[$0].id) })
        if c.table?.selectedRowIndexes != indexes { c.reloading = true; c.table?.selectRowIndexes(indexes, byExtendingSelection: false); c.reloading = false }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: FileTable
        var rows: [Entry]
        weak var table: CommanderTable?
        var reloading = false
        var focusObserver: NSObjectProtocol?
        init(_ parent: FileTable) { self.parent = parent; rows = parent.entries }
        deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
        func activate() { parent.tab.state.activeSide = parent.remote ? .remote : .local }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let tableColumn else { return nil }
            let entry = rows[row], id = tableColumn.identifier.rawValue
            if id == "name" {
                let cell = NSTableCellView(), icon = NSImageView(), text = NSTextField(labelWithString: entry.name)
                icon.image = NSImage(systemSymbolName: entry.directory ? "folder.fill" : entry.kind == .symlink ? "link" : "doc", accessibilityDescription: nil); icon.contentTintColor = entry.directory ? .systemBlue : .secondaryLabelColor
                text.font = .systemFont(ofSize: 12); text.lineBreakMode = .byTruncatingMiddle
                for child in [icon,text] { child.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(child) }
                NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 18), text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                return cell
            }
            let value: String
            switch id {
            case "size": value = entry.directory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
            case "modified": value = entry.modified
            case "permissions": value = entry.permissionText
            case "owner": value = "\(entry.attributes.uid ?? 0):\(entry.attributes.gid ?? 0)"
            default: value = entry.kind == .directory ? "資料夾" : entry.kind == .symlink ? "符號連結" : (entry.name as NSString).pathExtension.uppercased()
            }
            let text = NSTextField(labelWithString: value); text.font = .systemFont(ofSize: 11); text.textColor = .secondaryLabelColor; return text
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !reloading else { return }
            let ids = Set(table?.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil } ?? [])
            if parent.remote { parent.tab.state.remote.selection = ids } else { parent.tab.state.local.selection = ids }; activate()
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first else { return }
            let sort: FileSort = descriptor.key == "size" ? .size : descriptor.key == "modified" ? .modified : descriptor.key == "kind" ? .kind : .name
            if parent.remote { parent.tab.state.remote.sort = sort; parent.tab.state.remote.ascending = descriptor.ascending } else { parent.tab.state.local.sort = sort; parent.tab.state.local.ascending = descriptor.ascending }
            parent.model.saveWorkspace()
        }
        @objc func open() { guard let table, rows.indices.contains(table.clickedRow) else { return }; parent.model.navigate(rows[table.clickedRow], remote: parent.remote, tab: parent.tab) }
        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String, let column = table?.tableColumns.first(where: { $0.identifier.rawValue == id }) else { return }
            column.isHidden.toggle(); sender.state = column.isHidden ? .off : .on; table?.sizeToFit()
        }
        @objc func menuCommand(_ sender: NSMenuItem) { guard let text = sender.representedObject as? String, let command = FileCommand(rawValue: text) else { return }; parent.model.execute(command, tab: parent.tab) }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard rows.indices.contains(row) else { return nil }
            let entry = rows[row]
            if !parent.remote { return NSURL(fileURLWithPath: entry.path) }
            guard let connection = parent.tab.connection, parent.tab.connected else { return nil }
            let writer = PromiseWriter(entry: entry, connection: connection, model: parent.model, originTabID: parent.tab.id)
            return RetainedPromise.make(type: entry.directory ? UTType.folder.identifier : (UTType(filenameExtension: (entry.name as NSString).pathExtension)?.identifier ?? UTType.data.identifier), writer: writer)
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            if info.draggingSource as? NSTableView === tableView { return [] }
            if parent.remote && !parent.tab.connected { return [] }
            tableView.setDropRow(row, dropOperation: rows.indices.contains(row) && rows[row].directory ? .on : .above)
            return .copy
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            let directory = dropOperation == .on && rows.indices.contains(row) && rows[row].directory ? rows[row].path : (parent.remote ? parent.tab.state.remote.path : parent.tab.state.local.path)
            if let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                if parent.remote { parent.model.upload(urls, directory: directory, tab: parent.tab) } else { parent.model.copyLocal(urls, directory: directory, tab: parent.tab) }; return true
            }
            if let receivers = info.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !receivers.isEmpty {
                let originTabID = parent.tab.id, remote = parent.remote, model = parent.model, connection = parent.tab.connection, options = parent.model.options(for: parent.tab)
                let destination = remote ? AppStoragePaths.root.appendingPathComponent("incoming/" + UUID().uuidString) : URL(fileURLWithPath: directory)
                do { if remote { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } } catch { model.error = error.localizedDescription; return false }
                for receiver in receivers { receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .main) { url, error in
                    Task { @MainActor in
                        if let error { model.error = error.localizedDescription }
                        else if remote, let connection { var task = TransferTask(connection: connection, direction: .upload, source: url.path, destination: RemotePath.join(directory, url.lastPathComponent)); task.originTabID = originTabID; task.options = options; model.queue.enqueue(task) }
                        else { for tab in model.tabs { tab.refreshLocal() } }
                    }
                } }; return true
            }
            return false
        }
    }
}
