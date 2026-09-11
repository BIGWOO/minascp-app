import Foundation
import SwiftUI

enum PanelSide: String, Codable { case local, remote }
enum FileSort: String, Codable, CaseIterable { case name = "名稱", size = "大小", modified = "修改日期", kind = "種類" }
struct PanelState: Codable {
    var path: String
    var history: [String] = []
    var historyIndex = -1
    var filter = ""
    var sort: FileSort = .name
    var ascending = true
    var selection = Set<String>()
    var bookmarks: [String] = []
    mutating func visit(_ newPath: String) {
        if history.isEmpty { history = [path]; historyIndex = 0 }
        guard path != newPath else { return }
        if historyIndex + 1 < history.count { history = Array(history.prefix(historyIndex + 1)) }
        history.append(newPath); historyIndex = history.count - 1; path = newPath; selection.removeAll()
    }
    mutating func back(_ delta: Int) {
        let index = historyIndex + delta
        guard history.indices.contains(index) else { return }
        historyIndex = index; path = history[index]; selection.removeAll()
    }
}
struct WorkspaceTab: Identifiable, Codable {
    var id = UUID()
    var profile: SavedSite
    var local: PanelState
    var remote: PanelState
    var activeSide: PanelSide = .local
    var alias: String?
    var colorOverride: String?
    var title: String { alias?.isEmpty == false ? alias! : profile.name }
    var color: String { colorOverride ?? profile.color }
    init(profile: SavedSite) { self.profile = profile; local = PanelState(path: profile.localPath); remote = PanelState(path: profile.remotePath) }
}
struct WorkspaceDocument: Codable { var version = 1; var tabs: [WorkspaceTab]; var selected: UUID? }
@MainActor final class TabBrowser: ObservableObject, Identifiable {
    @Published var state: WorkspaceTab
    @Published var localEntries: [Entry] = []
    @Published var remoteEntries: [Entry] = []
    @Published var connected = false
    @Published var connecting = false
    @Published var error: String?
    @Published var synchronizedBrowsing = false
    var session: SFTPSession?
    var connection: Connection?
    var change: (() -> Void)?
    private var generation = 0
    var connectionGeneration: Int { generation }
    private var navigationVersion = 0
    var statusLabel: String { state.profile.host.isEmpty ? "本機" : connecting ? "連線中" : connected ? "已連線" : "未連線" }
    nonisolated let id: UUID
    init(_ state: WorkspaceTab) { self.id = state.id; self.state = state; refreshLocal() }
    func connect(authentication: AuthenticationCenter) async {
        guard !connecting, !connected else { return }
        if !state.profile.validationIssues.isEmpty { error = state.profile.validationIssues.joined(separator: "\n"); return }
        connecting = true; generation += 1; let version = generation
        do {
            let connection = try authentication.prepare(state.profile.connection)
            let session = try await SFTPSession.open(connection, captureInfo: true)
            guard generation == version else { await session.close(); return }
            self.connection = connection; self.session = session
            let path = try await session.canonical(state.remote.path.isEmpty ? "." : state.remote.path)
            let entries = try await session.list(path)
            guard generation == version else { await session.close(); return }
            state.remote.visit(path); remoteEntries = entries; connected = true; connecting = false; change?()
        } catch { guard generation == version else { return }; connecting = false; self.error = error.localizedDescription; await session?.close(); session = nil }
    }
    func disconnect() { generation += 1; connected = false; connecting = false; if let session { Task { await session.close() } }; session = nil; connection = nil }
    func refreshLocal() {
        do { localEntries = try LocalFiles.list(state.local.path); state.local.selection.formIntersection(Set(localEntries.map(\.id))) }
        catch { self.error = error.localizedDescription }
    }
    func refreshRemote() async {
        guard let session, connected else { return }
        let path = state.remote.path, version = generation
        do { let items = try await session.list(path); guard version == generation, path == state.remote.path else { return }; remoteEntries = items; state.remote.selection.formIntersection(Set(items.map(\.id))) }
        catch { self.error = error.localizedDescription; if !(await session.ready) { connected = false } }
    }
    func navigate(_ path: String, side: PanelSide, history: Bool = true) async {
        if side == .local {
            do { let entries = try LocalFiles.list(path); if history { state.local.visit(path) } else { state.local.path = path }; localEntries = entries; change?() }
            catch { self.error = error.localizedDescription }
        } else {
            guard let session else { error = "請先連線"; return }
            navigationVersion += 1; let navigation = navigationVersion, version = generation
            do { let canonical = try await session.canonical(path); let entries = try await session.list(canonical); guard navigation == navigationVersion, version == generation else { return }; if history { state.remote.visit(canonical) } else { state.remote.path = canonical }; remoteEntries = entries; change?() }
            catch { self.error = error.localizedDescription }
        }
    }
    func visible(remote: Bool, hidden: Bool) -> [Entry] {
        let panel = remote ? state.remote : state.local
        return (remote ? remoteEntries : localEntries).filter { (hidden || !$0.name.hasPrefix(".")) && (panel.filter.isEmpty || $0.name.localizedCaseInsensitiveContains(panel.filter)) }.sorted { a, b in
            if a.id == b.id { return false }
            if a.directory != b.directory { return a.directory }
            let ordered: Bool
            switch panel.sort {
            case .name: ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .size: ordered = a.size == b.size ? Entry.nameOrder(a,b) : a.size < b.size
            case .modified: ordered = a.attributes.modificationTime == b.attributes.modificationTime ? Entry.nameOrder(a,b) : (a.attributes.modificationTime ?? 0) < (b.attributes.modificationTime ?? 0)
            case .kind: ordered = a.kind == b.kind ? Entry.nameOrder(a,b) : a.kind.rawValue < b.kind.rawValue
            }
            return panel.ascending ? ordered : !ordered
        }
    }
}
