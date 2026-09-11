import AppKit
import Combine
import Sparkle

/// Shared by the updater and termination delegate; queued decisions are work too.
struct UpdateActivity {
    var transfers = false
    var commands = false
    var crossSite = false
    var properties = false
    var isBusy: Bool { transfers || commands || crossSite || properties }
    var reason: String {
        [transfers ? "檔案傳輸或衝突決策" : nil,
         commands ? "遠端指令" : nil, crossSite ? "跨站台複製" : nil,
         properties ? "屬性操作" : nil].compactMap { $0 }.joined(separator: "、")
    }
}

@MainActor final class UpdateRestartGate {
    private var continuation: (() -> Void)?
    private(set) var approved = false
    var pending: Bool { continuation != nil }
    func postpone(_ handler: @escaping () -> Void) { continuation = handler; approved = false }
    @discardableResult func resume(activity: UpdateActivity, confirmed: Bool) -> Bool {
        guard !activity.isBusy, confirmed, let handler = continuation else { return false }
        continuation = nil; approved = true; handler(); return true
    }
    func reset() { continuation = nil; approved = false }
    func approvedForImmediateInstall() { approved = true }
}

@MainActor final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    weak var model: BrowserModel?
    @Published private(set) var canCheck = true
    @Published private(set) var pendingRestart = false
    private(set) var preparingInstallation = false
    let restartGate = UpdateRestartGate()
    var report: (String, String) -> Void = { Dialogs.info($0, detail: $1) }
    var confirmRestart: () -> Bool = {
        Dialogs.confirm("安裝更新並重新啟動？", detail: "將儲存目前工作區與偏好設定，再重新啟動 MinaSCP。")
    }
    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?

    var activity: UpdateActivity {
        guard let model else { return UpdateActivity(properties: true) }
        return UpdateActivity(
            transfers: model.queue.activeCount > 0 || model.queue.records.contains { [.running, .waiting, .decision].contains($0.state) },
            commands: model.commands.activeCount > 0,
            crossSite: model.crossSite.activeCount > 0,
            properties: model.propertyEditor?.busy == true)
    }

    func checkForUpdates() {
        if pendingRestart { resumeInstallation(); return }
        guard canCheck else { return }
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty else {
            Dialogs.info("此開發版本尚未設定更新來源", detail: "請使用已設定更新簽章的安裝包。"); return
        }
        if controller == nil {
            let value = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
            value.updater.automaticallyChecksForUpdates = false
            value.updater.automaticallyDownloadsUpdates = false
            controller = value
            observation = value.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let allowed = updater.canCheckForUpdates
                Task { @MainActor [weak self] in self?.canCheck = allowed }
            }
            do { try value.updater.start() }
            catch { controller = nil; canCheck = true; Dialogs.info("無法啟動檢查更新", detail: error.localizedDescription); return }
        }
        controller?.checkForUpdates(nil)
    }

    // Once extraction starts Sparkle's helper can finish installation when the host
    // exits. Require the explicit Install and Relaunch choice before permitting exit.
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        preparingInstallation = true
    }

    var protectsTermination: Bool { preparingInstallation || restartGate.pending || restartGate.approved }
    var mustDelayTermination: Bool { !restartGate.approved || restartGate.pending || activity.isBusy }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeIfBusy(installHandler)
    }

    func postponeIfBusy(_ installHandler: @escaping () -> Void) -> Bool {
        if !activity.isBusy { restartGate.approvedForImmediateInstall(); return false }
        restartGate.postpone(installHandler); pendingRestart = true
        report("更新已下載，等待工作完成", "目前仍有\(activity.reason)。完成後請選擇 MinaSCP → 安裝更新並重新啟動…，再次確認安裝。")
        return true
    }

    // Sparkle's installer may request termination after work has started since
    // the first confirmation. Retry only the host termination, after fresh consent.
    func deferApprovedTerminationIfBusy() {
        guard restartGate.approved, activity.isBusy else { return }
        restartGate.postpone { NSApplication.shared.terminate(nil) }
        pendingRestart = true
    }

    func resumeInstallation() {
        guard !activity.isBusy else {
            report("目前無法重新啟動", "請先完成\(activity.reason)，再安裝更新。"); return
        }
        let confirmed = confirmRestart()
        // Re-read after the modal dialog: work may have started while it was open.
        if restartGate.resume(activity: activity, confirmed: confirmed) { pendingRestart = false }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { resetAfterUpdateCycle() }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if !pendingRestart { resetAfterUpdateCycle() }
    }

    func resetAfterUpdateCycle() {
        restartGate.reset(); pendingRestart = false; preparingInstallation = false
    }
}
