import SwiftUI

struct ContentView: View {
    @ObservedObject var model: BrowserModel
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            WorkspaceSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                tabStrip
                if let tab = model.current {
                    HSplitView {
                        FilePane(model: model, tab: tab, remote: false)
                        FilePane(model: model, tab: tab, remote: true)
                    }.padding(.horizontal, 12).id(tab.id)
                    if let error = tab.error { ErrorBanner(text: error) { tab.error = nil } }
                }
                TransferQueueView(model: model).padding(12)
                if let error = model.error ?? model.queue.persistenceError ?? model.authentication.error ?? model.edits.error {
                    ErrorBanner(text: error) {
                        model.error = nil; model.queue.persistenceError = nil
                        model.authentication.error = nil; model.edits.error = nil
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { workspaceToolbar }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .sheet(isPresented: Binding(get: { hasSheet }, set: { if !$0 { dismissSheets() } }), onDismiss: { model.flushAppearancePreferences() }) {
            PresentationView(model: model)
                .interactiveDismissDisabled(!model.authentication.prompts.isEmpty || !model.queue.conflicts.isEmpty || model.propertyEditor?.busy == true)
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.tabs) { tab in WorkspaceTabChip(model: model, tab: tab) }
                Button { model.newSite() } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).help("新增分頁 ⌘T").accessibilityLabel("新增分頁")
            }.padding(.horizontal, 12).padding(.vertical, 9)
        }
    }

    @ToolbarContentBuilder private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button { model.execute(.mkdir) } label: { Label("新增資料夾", systemImage: "folder.badge.plus") }
                .disabled(!allows(.mkdir)).help("新增資料夾 F7")
        }
        ToolbarItem(placement: .automatic) {
            Button { model.execute(.copy) } label: {
                Label(model.current?.state.activeSide == .remote ? "下載" : "上傳", systemImage: model.current?.state.activeSide == .remote ? "arrow.down" : "arrow.up")
            }.labelStyle(.titleAndIcon).disabled(!allows(.copy)).minaPrimaryButton().help("將選取項目傳輸到另一欄 F5")
        }
        ToolbarItem(placement: .automatic) {
            Button { model.refreshLocal(); model.refreshRemote() } label: { Label("重新整理", systemImage: "arrow.clockwise") }
                .help("重新整理 ⌘R")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.requestPaneFocus(.filter) } label: { Label("篩選", systemImage: "line.3.horizontal.decrease") }
                .help("篩選目前面板 ⌘F")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach([FileCommand.preview, .edit, .rename, .delete, .properties], id: \.self) { command in
                    Button { model.execute(command) } label: { Label(command.rawValue, systemImage: command.symbol) }
                        .disabled(!allows(command))
                }
                Divider()
                Button { configureSync() } label: { Label("比較／同步", systemImage: "arrow.triangle.2.circlepath") }.disabled(!model.connected)
                Button { model.execute(.search) } label: { Label("尋找檔案…", systemImage: "magnifyingglass") }.disabled(!allows(.search))
                Button { model.commands.showManager = true } label: { Label("自訂指令…", systemImage: "terminal") }
                Divider()
                if let tab = model.current {
                    if tab.connecting { Button("取消連線") { model.performTab(.cancelConnection, id: tab.id) } }
                    else if tab.connected {
                        Button("重新連線") { model.performTab(.reconnect, id: tab.id) }
                        Button("中斷連線") { model.performTab(.disconnect, id: tab.id) }
                        Button("連線資訊…") { model.presentConnectionInfo(tab) }
                    } else { Button("連線") { model.performTab(.connect, id: tab.id) }.disabled(tab.state.profile.host.isEmpty) }
                }
            } label: { Label("更多操作", systemImage: "ellipsis.circle") }.help("更多檔案與連線操作")
        }
    }
    private func allows(_ command: FileCommand) -> Bool { model.current.map { CommandContext(tab: $0).allows(command) } ?? false }
    private func configureSync() {
        guard let tab = model.current, tab.connected else { return }
        model.sync.configure(tab, exclusions: model.preferences.exclusions); model.showSync = true
    }
    private var hasSheet: Bool {
        !model.authentication.prompts.isEmpty || !model.queue.conflicts.isEmpty || model.showPreferences || model.showImport || model.showSync || model.showEdits || model.showSearch || model.preview != nil || model.propertyEditor != nil || model.copyContext != nil || model.commands.preview != nil || model.commands.showManager || model.commands.showJobs || model.crossSite.showJobs
    }
    private func dismissSheets() {
        model.flushAppearancePreferences()
        model.showPreferences = false; model.showImport = false; model.showSync = false
        model.showEdits = false; model.showSearch = false; model.preview = nil; model.propertyEditor = nil
        model.copyContext = nil; model.commands.preview = nil; model.commands.showManager = false
        model.commands.showJobs = false; model.crossSite.showJobs = false
    }
}

private struct WorkspaceSidebar: View {
    @ObservedObject var model: BrowserModel
    @State private var selectedSite: UUID?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("站台").font(.headline)
                Spacer()
                Button { model.newSite() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("新增站台").accessibilityLabel("新增站台")
            }.padding(.horizontal, 18).padding(.top, 14)
            TextField("搜尋站台", text: $model.siteSearch)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 12)
            List(selection: $selectedSite) {
                ForEach(groups, id: \.self) { group in
                    Section(group.isEmpty ? "我的站台" : group) {
                        ForEach(sites(in: group)) { site in
                            HStack(spacing: 10) {
                                Image(systemName: "server.rack").font(.system(size: 16)).foregroundStyle(.secondary)
                                Text(site.name).lineLimit(1)
                                Spacer(minLength: 2)
                                Circle().fill(siteColor(site.color)).frame(width: 6, height: 6)
                            }.padding(.vertical, 5).tag(site.id)
                                .contentShape(Rectangle()).onTapGesture(count: 2) { model.openSite(site) }
                                .contextMenu {
                                    Button("開啟新分頁") { model.openSite(site) }
                                    Button("編輯站台") { model.selectSite(site) }
                                    Button("複製站台") { model.duplicateSite(site) }
                                    Button("移除站台") { model.deleteSite(site) }
                                }
                        }
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                .onChange(of: model.selectedTabID) { _, _ in selectedSite = model.current?.state.profile.id }
                .onAppear { selectedSite = model.current?.state.profile.id }
                .onKeyPress(.return) {
                    guard let site = model.sites.first(where: { $0.id == selectedSite }) else { return .ignored }
                    model.openSite(site); return .handled
                }
            VStack(alignment: .leading, spacing: 5) {
                sidebarButton("站台管理", icon: "server.rack") { model.showConnection = true }
                sidebarButton("遠端編輯", icon: "square.and.pencil", count: model.edits.records.count) { model.showEdits = true }
                sidebarButton("跨站台工作", icon: "arrow.left.arrow.right") { model.crossSite.showJobs = true }
                sidebarButton("指令工作", icon: "terminal") { model.commands.showJobs = true }
                Divider().padding(.vertical, 7)
                sidebarButton("偏好設定", icon: "gearshape") { model.showPreferences = true }
            }.padding(.horizontal, 12).padding(.bottom, 16)
        }
    }
    private var groups: [String] { Array(Set(model.sites.map(\.group))).sorted() }
    private func sites(in group: String) -> [SavedSite] {
        model.sites.filter { $0.group == group && (model.siteSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(model.siteSearch) || $0.host.localizedCaseInsensitiveContains(model.siteSearch)) }
    }
    private func sidebarButton(_ title: String, icon: String, count: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20)
                Text(title)
                Spacer(minLength: 0)
                if count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
            }.padding(.horizontal, 7).padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(.plain).font(.system(size: 13))
    }
}
