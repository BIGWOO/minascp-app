import SwiftUI
import AppKit
import Darwin

struct PropertyChange {
    var permissionMask: UInt32 = 0
    var permissionBits: UInt32 = 0
    var uid: UInt32?
    var gid: UInt32?
    var empty: Bool { permissionMask == 0 && uid == nil && gid == nil }
    func attributes(for original: FileAttributes) -> FileAttributes {
        var result = FileAttributes()
        if permissionMask == 0o7777 { result.permissions = permissionBits & 0o7777 }
        else if permissionMask != 0, let mode = original.permissions { result.permissions = ((mode & 0o7777) & ~permissionMask) | (permissionBits & permissionMask) }
        // SFTP v3 carries UID and GID together; preserve whichever field was not edited.
        if uid != nil || gid != nil { result.uid = uid ?? original.uid; result.gid = gid ?? original.gid }
        return result
    }
    func verified(_ actual: FileAttributes, expected: FileAttributes) -> Bool {
        (expected.permissions == nil || actual.permissions.map { $0 & 0o7777 } == expected.permissions) && (expected.uid == nil || actual.uid == expected.uid) && (expected.gid == nil || actual.gid == expected.gid)
    }
}
struct PropertySnapshot: Identifiable {
    var id: String { path }
    let path: String
    let attributes: FileAttributes
    let link: String?
}
@MainActor final class FilePropertyEditor: ObservableObject {
    let context: CommandContext
    @Published var snapshots: [PropertySnapshot] = []
    @Published var messages: [String] = []
    @Published var busy = false
    @Published var recursive = false
    @Published var change = PropertyChange()
    @Published var octal = ""
    @Published var uidText = ""
    @Published var gidText = ""
    @Published var editUID = false
    @Published var editGID = false
    @Published var octalError = false
    private var appliedChange = PropertyChange()
    @Published var originals: [PropertySnapshot] = []
    init(_ context: CommandContext) { self.context = context }
    func read(_ path: String) async throws -> FileAttributes { context.remote ? try await context.session!.attributes(path) : try LocalFiles.attributes(path) }
    func load() async {
        busy = true; defer { busy = false }
        var result: [PropertySnapshot] = []
        for entry in context.entries {
            do {
                guard context.valid else { throw TransferError.message("連線已改變") }
                let attr = try await read(entry.path)
                let link: String? = attr.kind == .symlink ? (context.remote ? try await context.session!.readlink(entry.path) : try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)) : nil
                result.append(PropertySnapshot(path: entry.path, attributes: attr, link: link))
            } catch { messages.append("\(entry.path)：\(error.localizedDescription)") }
        }
        snapshots = result
        if let first = result.first {
            octal = result.allSatisfy { $0.attributes.permissions.map { $0 & 0o7777 } == first.attributes.permissions.map { $0 & 0o7777 } } ? String(format: "%04o", (first.attributes.permissions ?? 0) & 0o7777) : ""
            uidText = result.allSatisfy { $0.attributes.uid == first.attributes.uid } ? first.attributes.uid.map(String.init) ?? "" : ""
            gidText = result.allSatisfy { $0.attributes.gid == first.attributes.gid } ? first.attributes.gid.map(String.init) ?? "" : ""
        }
    }
    func bitState(_ bit: UInt32) -> Int {
        if change.permissionMask & bit != 0 { return change.permissionBits & bit != 0 ? 1 : 0 }
        let values = Set(snapshots.map { ($0.attributes.permissions ?? 0) & bit != 0 })
        return values.count > 1 ? -1 : values.first == true ? 1 : 0
    }
    func toggleBit(_ bit: UInt32) {
        let enable = bitState(bit) != 1
        change.permissionMask |= bit
        if enable { change.permissionBits |= bit } else { change.permissionBits &= ~bit }
        octalError = false
        let modes = Set(snapshots.compactMap { change.attributes(for: $0.attributes).permissions })
        octal = modes.count == 1 ? String(format: "%04o", modes.first!) : ""
    }
    func setOctal(_ value: String) {
        octal = value
        guard value.range(of: "^[0-7]{3,4}$", options: .regularExpression) != nil, let bits = UInt32(value, radix: 8) else { octalError = true; return }
        octalError = false; change.permissionMask = 0o7777; change.permissionBits = bits
    }
    private func write(_ path: String, attributes: FileAttributes) async throws {
        guard context.valid else { throw TransferError.message("連線已改變") }
        guard try await read(path).kind != .symlink else { throw TransferError.message("略過符號連結") }
        if context.remote { try await context.session!.setAttributesNoFollow(path, attributes) }
        else {
            if attributes.uid != nil || attributes.gid != nil {
                guard lchown(path, attributes.uid ?? UInt32.max, attributes.gid ?? UInt32.max) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            if let mode = attributes.permissions {
                guard lchmod(path, mode_t(mode)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        }
        let actual = try await read(path)
        guard change.verified(actual, expected: attributes) else { throw TransferError.message("寫入後讀回不符") }
    }
    func apply() async {
        guard !busy, !octalError else { return }
        if editUID { guard let uid = UInt32(uidText) else { messages = ["UID 必須為有效數字"]; return }; change.uid = uidText.isEmpty ? nil : uid } else { change.uid = nil }
        if editGID { guard let gid = UInt32(gidText) else { messages = ["GID 必須為有效數字"]; return }; change.gid = gid } else { change.gid = nil }
        guard !change.empty else { return }
        busy = true; messages = []; defer { busy = false }
        var targets: [PropertySnapshot] = [], seen = Set<String>()
        func collect(_ path: String) async throws {
            guard seen.insert(path).inserted else { return }; try Task.checkCancellation()
            let attr = try await read(path)
            if attr.kind == .symlink { messages.append("略過連結：\(path)"); return }
            targets.append(PropertySnapshot(path: path, attributes: attr, link: nil))
            if recursive && attr.kind == .directory {
                let children = context.remote ? try await context.session!.list(path) : try LocalFiles.list(path)
                for child in children { try await collect(child.path) }
            }
        }
        // Collect the complete readable scope before mutating any item.
        do { for entry in context.entries { try await collect(entry.path) } }
        catch { messages.append("尚未寫入：\(error.localizedDescription)"); return }
        guard targets.allSatisfy({ item in
            (change.permissionMask == 0 || item.attributes.permissions != nil) &&
            ((change.uid == nil && change.gid == nil) || (item.attributes.uid != nil && item.attributes.gid != nil))
        }) else { messages.append("尚未寫入：缺少原始權限或擁有者資訊，無法安全套用與還原"); return }
        originals = targets; appliedChange = change
        // Children first: removing parent traversal permission must not prevent child updates.
        for item in targets.sorted(by: { $0.path.split(separator: "/").count > $1.path.split(separator: "/").count }) {
            do { try await write(item.path, attributes: change.attributes(for: item.attributes)); messages.append("已讀回確認：\(item.path)") }
            catch { messages.append("失敗：\(item.path)：\(error.localizedDescription)") }
        }
        change = PropertyChange(); editUID = false; editGID = false
        await load()
        context.tab.refreshLocal(); await context.tab.refreshRemote()
    }
    func restore() async {
        guard !busy else { return }; busy = true; messages = []; defer { busy = false }
        for item in originals.sorted(by: { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }) {
            do {
                var attr = FileAttributes()
                if appliedChange.permissionMask != 0 { attr.permissions = item.attributes.permissions.map { $0 & 0o7777 } }
                if appliedChange.uid != nil || appliedChange.gid != nil { attr.uid = item.attributes.uid; attr.gid = item.attributes.gid }
                try await write(item.path, attributes: attr); messages.append("已還原並讀回：\(item.path)")
            } catch { messages.append("還原失敗：\(item.path)：\(error.localizedDescription)") }
        }
        change = PropertyChange(); editUID = false; editGID = false
        await load()
        context.tab.refreshLocal(); await context.tab.refreshRemote()
    }
}
struct FilePropertiesView: View {
    @ObservedObject var editor: FilePropertyEditor
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("屬性 · \(editor.context.entries.count) 個項目").font(.headline); Spacer(); Button("關閉", action: close).disabled(editor.busy) }
            ScrollView { VStack(alignment: .leading, spacing: 8) {
                ForEach(editor.snapshots) { item in
                    Text(item.path).fontWeight(.medium).textSelection(.enabled)
                    Text("\(item.attributes.kind.rawValue) · \(item.attributes.size ?? 0) bytes · UID:GID \(item.attributes.uid.map(String.init) ?? "未知"):\(item.attributes.gid.map(String.init) ?? "未知")").font(.caption)
                    if let time = item.attributes.modificationTime { Text("修改：" + Date(timeIntervalSince1970: Double(time)).formatted()).font(.caption) }
                    if let link = item.link { Text("連結目標：\(link)").font(.caption) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
            Divider()
            Text("權限（— 表示混合值；只套用有修改的欄位）").font(.caption)
            ForEach(Array([("擁有者",6),("群組",3),("其他",0)].enumerated()), id: \.offset) { _, pair in
                HStack { Text(pair.0).frame(width: 75, alignment: .leading)
                    ForEach(Array([("R",4),("W",2),("X",1)].enumerated()), id: \.offset) { _, permission in
                        let bit = UInt32(permission.1 << pair.1)
                        Button { editor.toggleBit(bit) } label: { Label(permission.0, systemImage: editor.bitState(bit) == -1 ? "minus.square" : editor.bitState(bit) == 1 ? "checkmark.square.fill" : "square") }.buttonStyle(.plain).frame(width: 65).accessibilityValue(editor.bitState(bit) == -1 ? "混合" : editor.bitState(bit) == 1 ? "勾選" : "未勾選")
                    }
                }
            }
            HStack { Text("八進位"); TextField("混合值", text: Binding(get: { editor.octal }, set: { editor.setOctal($0) })).frame(width: 90); if editor.octalError { Text("請輸入 3～4 位八進位數字").foregroundStyle(.red) } }
            HStack { Toggle("修改 UID", isOn: $editor.editUID); TextField("混合／未知", text: $editor.uidText).disabled(!editor.editUID); Toggle("修改 GID", isOn: $editor.editGID); TextField("混合／未知", text: $editor.gidText).disabled(!editor.editGID) }
            Toggle("遞迴套用至所選資料夾內所有檔案與子目錄", isOn: $editor.recursive)
            Text("不跟隨符號連結；套用前保存本次原值，失敗逐項顯示。").font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(editor.messages.joined(separator: "\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 100)
            HStack { if editor.busy { ProgressView().controlSize(.small) }; Button("還原本次原值") { Task { await editor.restore() } }.disabled(editor.originals.isEmpty || editor.busy); Spacer(); Button("套用變更") { Task { await editor.apply() } }.disabled(editor.busy || editor.octalError || editor.snapshots.isEmpty) }
        }.padding(22).frame(width: 660).disabled(editor.busy).task { await editor.load() }
    }
}
extension BrowserModel {
    func showProperties(_ context: CommandContext) { propertyEditor = FilePropertyEditor(context) }
}
