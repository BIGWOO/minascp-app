import SwiftUI

struct FilePane: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var tab: TabBrowser
    let remote: Bool
    @State private var pathInput = ""
    @State private var editingPath = false
    @State private var showingFilter = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case path, filter }
    private var side: PanelSide { remote ? .remote : .local }
    private var panel: PanelState { remote ? tab.state.remote : tab.state.local }
    private var active: Bool { tab.state.activeSide == side }

    var body: some View {
        VStack(spacing: 0) {
            header
            pathBar
            if showingFilter || !panel.filter.isEmpty { filterBar }
            if remote && !tab.connected { disconnectedState }
            else { FileTable(model: model, tab: tab, remote: remote) }
            footer
        }
        .frame(minWidth: 320)
        .background(Color.primary.opacity(active ? 0.025 : 0.012), in: RoundedRectangle(cornerRadius: 14))
        .onAppear { pathInput = panel.path; showingFilter = !panel.filter.isEmpty }
        .onChange(of: panel.path) { _, path in pathInput = path }
        .onChange(of: focusedField) { _, field in
            if field != nil { activate() }
            if field != .path { editingPath = false; pathInput = panel.path }
        }
        .onReceive(NotificationCenter.default.publisher(for: .minaPaneFocus)) { notification in
            guard let request = notification.object as? PaneFocusRequest,
                  request.tabID == tab.id, request.side == side else { return }
            if request.target == .path { beginPathEditing() } else { beginFiltering() }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: remote ? "server.rack" : "laptopcomputer")
                .font(.system(size: 19, weight: .regular)).foregroundStyle(active ? Color.accentColor : .secondary)
            Text(remote ? (tab.state.profile.host.isEmpty ? "遠端伺服器" : tab.state.title) : "本機")
                .font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if remote {
                HStack(spacing: 5) {
                    if tab.connecting { ProgressView().controlSize(.mini) }
                    else { Circle().fill(tab.connected ? Color.green : .secondary).frame(width: 6, height: 6) }
                    Text(tab.statusLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.04), in: Capsule())
            }
            Menu {
                Button("編輯路徑 ⌘L") { beginPathEditing() }
                Button("篩選名稱 ⌘F") { beginFiltering() }
                Divider()
                Toggle("顯示隱藏檔案", isOn: Binding(get: { model.showHidden }, set: { model.showHidden = $0 }))
                Menu("排序") {
                    ForEach(FileSort.allCases, id: \.self) { sort in
                        Button { setSort(sort) } label: {
                            if panel.sort == sort { Label(sort.rawValue, systemImage: "checkmark") } else { Text(sort.rawValue) }
                        }
                    }
                    Divider()
                    Button("反向排序") {
                        if remote { tab.state.remote.ascending.toggle() } else { tab.state.local.ascending.toggle() }
                        model.saveWorkspace()
                    }
                }
                Divider()
                Button("上層目錄") { navigate(RemotePath.parent(panel.path)) }
                Button("家目錄") { execute(.home) }
                if remote, tab.connected {
                    Divider()
                    Button("連線資訊…") { model.presentConnectionInfo(tab) }
                    Button("重新連線") { model.performTab(.reconnect, id: tab.id) }
                    Button("中斷連線") { model.performTab(.disconnect, id: tab.id) }
                }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17)) }
                .menuStyle(.borderlessButton).frame(width: 25).help(remote ? "遠端面板選項" : "本機面板選項")
        }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            .contentShape(Rectangle()).onTapGesture { activate() }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button { activate(); model.history(-1, remote: remote, tab: tab) } label: { Image(systemName: "chevron.left") }
                .disabled(panel.historyIndex <= 0).help("返回").accessibilityLabel("返回")
            Button { activate(); model.history(1, remote: remote, tab: tab) } label: { Image(systemName: "chevron.right") }
                .disabled(panel.historyIndex + 1 >= panel.history.count).help("往前").accessibilityLabel("往前")
            Group {
                if editingPath {
                    TextField("完整路徑", text: $pathInput)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).focused($focusedField, equals: .path)
                        .onSubmit { let path = pathInput; editingPath = false; focusedField = nil; navigate(path) }
                        .onExitCommand { editingPath = false; pathInput = panel.path; focusTable() }
                        .accessibilityLabel(remote ? "遠端完整路徑" : "本機完整路徑")
                } else {
                    PaneBreadcrumbs(path: panel.path, navigate: navigate)
                        .help(panel.path + "\n⌘L 編輯完整路徑")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            Button { beginPathEditing() } label: { Image(systemName: "pencil") }
                .help("編輯路徑 ⌘L").accessibilityLabel("編輯路徑")
            Menu {
                Button("加入書籤") { execute(.bookmark) }
                if !panel.bookmarks.isEmpty {
                    Divider()
                    ForEach(panel.bookmarks, id: \.self) { path in Button(path) { navigate(path) } }
                }
                if !panel.history.isEmpty {
                    Divider()
                    Menu("最近路徑") {
                        ForEach(Array(panel.history.suffix(10).enumerated()), id: \.offset) { _, path in Button(path) { navigate(path) } }
                    }
                }
            } label: { Image(systemName: "bookmark") }.menuStyle(.borderlessButton).frame(width: 20).help("路徑書籤")
        }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.bottom, 10)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(remote ? "篩選遠端檔案" : "篩選本機檔案", text: Binding(get: { panel.filter }, set: { value in
                if remote { tab.state.remote.filter = value } else { tab.state.local.filter = value }
                model.saveWorkspace()
            })).textFieldStyle(.plain).focused($focusedField, equals: .filter)
                .onSubmit { focusTable() }.onExitCommand { closeFilter() }
            Button { closeFilter() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).accessibilityLabel("清除並關閉篩選")
        }.font(.system(size: 12)).padding(9)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 14).padding(.bottom, 10)
    }

    private var disconnectedState: some View {
        VStack(spacing: 14) {
            Image(systemName: "server.rack").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
            Text(tab.connecting ? "正在連線…" : "準備連線").font(.title3.weight(.semibold))
            Text(tab.state.profile.host.isEmpty ? "選擇站台，開始瀏覽遠端檔案" : tab.state.profile.host)
                .font(.callout).foregroundStyle(.secondary)
            Button(tab.state.profile.host.isEmpty ? "選擇站台" : "連線") {
                activate()
                if tab.state.profile.host.isEmpty { model.showConnection = true } else { model.performTab(.connect, id: tab.id) }
            }.minaPrimaryButton().disabled(tab.connecting)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("\(tab.visible(remote: remote, hidden: model.showHidden).count) 個項目")
            if !panel.selection.isEmpty { Text("· 已選 \(panel.selection.count)") }
            Spacer(minLength: 4)
            if remote { Toggle("同步瀏覽", isOn: $tab.synchronizedBrowsing).toggleStyle(.checkbox) }
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func activate() { tab.state.activeSide = side }
    private func navigate(_ path: String) {
        activate()
        Task {
            await tab.navigate(path, side: side)
            pathInput = panel.path
            model.saveWorkspace()
        }
    }
    private func execute(_ command: FileCommand) { activate(); model.execute(command, context: CommandContext(tab: tab, background: true, side: side)) }
    private func setSort(_ sort: FileSort) {
        if remote { tab.state.remote.sort = sort } else { tab.state.local.sort = sort }
        model.saveWorkspace()
    }
    private func beginPathEditing() {
        activate(); pathInput = panel.path; editingPath = true
        Task { @MainActor in await Task.yield(); focusedField = .path }
    }
    private func beginFiltering() {
        activate(); showingFilter = true
        Task { @MainActor in await Task.yield(); focusedField = .filter }
    }
    private func closeFilter() {
        if remote { tab.state.remote.filter = "" } else { tab.state.local.filter = "" }
        showingFilter = false; model.saveWorkspace(); focusTable()
    }
    private func focusTable() {
        focusedField = nil
        NotificationCenter.default.post(name: .init("MinaSCP.FocusPanel"), object: nil)
    }
}

struct PathCrumb: Identifiable, Equatable {
    let path: String
    let title: String
    var id: String { path }
    static func components(of path: String) -> [PathCrumb] {
        var result = [PathCrumb(path: "/", title: "/")]
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            result.append(PathCrumb(path: current, title: String(component)))
        }
        return result
    }
}

private struct PaneBreadcrumbs: View {
    let path: String
    let navigate: (String) -> Void
    private var crumbs: [PathCrumb] { PathCrumb.components(of: path) }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                ForEach(crumbs) { crumb in
                    if crumb.path != "/" { separator }
                    crumbButton(crumb)
                }
            }.fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 5) {
                if crumbs.count > 2 {
                    Menu {
                        ForEach(crumbs.dropLast(2)) { crumb in Button(crumb.path) { navigate(crumb.path) } }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 18)
                }
                ForEach(Array(crumbs.suffix(2))) { crumb in
                    if crumb.path != "/" { separator }
                    crumbButton(crumb).lineLimit(1).truncationMode(.middle)
                }
            }
        }.font(.system(size: 12))
    }
    private var separator: some View { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
    private func crumbButton(_ crumb: PathCrumb) -> some View {
        Button { navigate(crumb.path) } label: { Text(crumb.title).foregroundStyle(crumb.path == path ? Color.primary : .secondary) }
            .buttonStyle(.plain).help(crumb.path).accessibilityLabel("前往 " + crumb.path)
    }
}
