import Foundation

enum TransferState: String, Codable, Sendable { case waiting = "等待", running = "傳輸中", paused = "已暫停", decision = "等待決策", complete = "完成", failed = "失敗", cancelled = "已取消" }
enum TransferDirection: String, Codable, Sendable { case upload = "上傳", download = "下載", local = "本機複製", remoteCopy = "遠端複製" }
enum CollisionPolicy: String, Codable, CaseIterable, Sendable { case ask = "詢問", overwrite = "覆蓋", skip = "略過", rename = "自動改名", newer = "僅較新檔" }
struct TransferOptions: Codable, Equatable, Sendable {
    var policy: CollisionPolicy = .ask
    var preserveTime = true
    var preservePermissions = false
    var speedLimit: Int = 0
}
struct SourceFingerprint: Codable, Equatable, Sendable {
    let size: UInt64
    let modificationTime: UInt32?
    let sha256: String
}
struct TransferItem: Codable, Sendable {
    let relativePath: String
    let source: String
    let kind: FileKind
    let attributes: FileAttributes
}
struct FileCheckpoint: Codable, Sendable {
    let source: SourceFingerprint
    let staging: String
    var destination: String
    var completed = false
}
enum SameSideOperation: String, Codable, Sendable { case copy, move }
struct TransferTask: Identifiable, Codable, Sendable {
    var id = UUID()
    var batchID = UUID()
    var connection: Connection
    var direction: TransferDirection
    var source: String
    var destination: String
    var options = TransferOptions()
    var state: TransferState = .waiting
    var transferred: UInt64 = 0
    var total: UInt64 = 0
    var message = ""
    var items: [TransferItem] = []
    var checkpoints: [String: FileCheckpoint] = [:]
    var created = Date()
    var sourceRemovalPending = false
    var currentFileBytes: UInt64?
    var currentFileSize: UInt64?
    var skippedCount: Int?
    var linkTargets: [String: String]?
    var sameSideOperation: SameSideOperation?
    var originTabID: UUID?
    var crossSiteJobID: UUID?
    var noOverwriteCopy: Bool?
    var crossRootCreated: Bool?
    var rootPrepared: Bool?
    var expectedSourceHash: String?
    var expectedDestinationHash: String?
    var operationLabel: String { sameSideOperation == .move ? (direction == .local ? "本機移動" : "遠端移動") : direction.rawValue }
    var name: String { (source as NSString).lastPathComponent }
}
struct TransferConflict: Identifiable, Sendable {
    var id = UUID()
    let taskID: UUID
    let source: String
    let destination: String
    let sourceAttributes: FileAttributes
    let destinationAttributes: FileAttributes
    var safeOnly = false
}
struct ConflictResolution: Sendable { var policy: CollisionPolicy; var applyToBatch = false }
typealias ConflictHandler = @Sendable (TransferConflict) async throws -> ConflictResolution
typealias TransferUpdate = @Sendable (TransferTask) -> Void
