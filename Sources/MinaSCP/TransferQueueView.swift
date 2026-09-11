import SwiftUI

struct TransferQueueView: View {
    @ObservedObject var model: BrowserModel
    private var pending: [TransferTask] { model.queue.records.filter { [.running, .waiting, .decision].contains($0.state) } }
    private var issues: Int { model.queue.records.filter { [.failed, .decision].contains($0.state) }.count }
    private var current: TransferTask? { pending.first(where: { $0.state == .running }) ?? pending.first }
    private var completed: Int { model.queue.records.filter { $0.state == .complete }.count }

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.animation(minimumInterval: 1, paused: pending.isEmpty)) { _ in summary }
                .minaControlSurface(cornerRadius: 14)
            if model.preferences.queueExpanded {
                if model.queue.records.isEmpty {
                    Text("拖曳檔案開始傳輸，進度與驗證結果會顯示在這裡。")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(model.queue.records) { record in
                                TimelineView(.animation(minimumInterval: 1, paused: record.state != .running)) { _ in row(record) }
                            }
                        }.padding(14)
                    }.frame(height: 160)
                }
            }
        }.background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
    }

    private var summary: some View {
        HStack(spacing: 12) {
            Button {
                model.preferences.queueExpanded.toggle(); model.savePreferences()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: model.preferences.queueExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 17))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current == nil ? "傳輸佇列" : "傳輸中 · \(pending.count)").font(.system(size: 12, weight: .semibold))
                        Text(current?.name ?? (model.queue.records.isEmpty ? "準備就緒" : "已完成 \(completed)／\(model.queue.records.count)"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(model.preferences.queueExpanded ? "收合傳輸佇列" : "展開傳輸佇列")
            Spacer(minLength: 8)
            if issues > 0 {
                Button {
                    model.preferences.queueExpanded = true; model.savePreferences()
                } label: { Label("\(issues) 項需處理", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                    .buttonStyle(.plain).font(.system(size: 12))
            }
            if let record = current {
                ProgressView(value: progress(record)).frame(width: 110)
                Text("\(Int(progress(record) * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                Button { pauseAll() } label: { Image(systemName: "pause.fill") }.help("暫停所有傳輸").accessibilityLabel("暫停所有傳輸")
            }
            Menu {
                Button(model.preferences.queueExpanded ? "收合傳輸佇列" : "展開傳輸佇列") { model.preferences.queueExpanded.toggle(); model.savePreferences() }
                Button("全部暫停") { pauseAll() }.disabled(pending.isEmpty)
                Button("清除完成") { model.queue.clearCompleted() }.disabled(completed == 0)
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24).help("傳輸佇列選項")
        }.padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func row(_ record: TransferTask) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.direction == .upload ? "arrow.up.doc" : "arrow.down.doc").foregroundStyle(.blue).frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(record.name).lineLimit(1)
                    Text(record.operationLabel).foregroundStyle(.secondary)
                    Spacer()
                    Text(record.state.rawValue).foregroundStyle(record.state == .failed ? .red : record.state == .complete ? .green : .secondary)
                }
                if record.state != .complete { ProgressView(value: progress(record)) }
                if record.state == .running, let size = record.currentFileSize, let bytes = record.currentFileBytes {
                    Text("目前檔案：\(Int(min(100, Double(bytes) / Double(max(1, size)) * 100)))%").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack {
                    if record.sameSideOperation != .move {
                        Text("\(formattedBytes(record.transferred)) / \(formattedBytes(record.total))")
                    }
                    if model.queue.speed(record) > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(model.queue.speed(record)), countStyle: .file))/s · 剩餘 \(Int(Double(record.total > record.transferred ? record.total - record.transferred : 0) / model.queue.speed(record))) 秒")
                    }
                    Spacer()
                    if !record.message.isEmpty { Text(record.message).lineLimit(1).help(record.message) }
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if [.running, .waiting, .decision].contains(record.state) {
                Button { model.queue.stop(record.id, pause: true) } label: { Image(systemName: "pause") }.help("暫停").accessibilityLabel("暫停 " + record.name)
                Button { model.queue.stop(record.id, pause: false) } label: { Image(systemName: "xmark") }.help("取消").accessibilityLabel("取消 " + record.name)
            } else if record.state != .complete && record.crossSiteJobID == nil {
                Button { model.queue.retry(record.id) } label: { Image(systemName: "arrow.clockwise") }.help("重試").accessibilityLabel("重試 " + record.name)
            }
            Button {
                Dialogs.info(record.name, detail: "\(record.source)\n→ \(record.destination)\n\(record.message)\n" + record.checkpoints.values.filter { !$0.completed }.map { "保留暫存：" + $0.staging }.joined(separator: "\n"))
            } label: { Image(systemName: "info.circle") }.help("傳輸資訊").accessibilityLabel("傳輸資訊 " + record.name)
        }.buttonStyle(.borderless).font(.system(size: 12))
    }
    private func pauseAll() { for record in pending { model.queue.stop(record.id, pause: true) } }
    private func progress(_ record: TransferTask) -> Double { record.state == .complete ? 1 : Double(min(record.transferred, record.total)) / Double(max(1, record.total)) }
    private func formattedBytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }
}
