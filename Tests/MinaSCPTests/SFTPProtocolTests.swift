import XCTest
@testable import MinaSCP
final class SFTPProtocolTests: XCTestCase {
    func testFramingSplitAndCoalescedPackets() throws {
        var p = PacketWriter(); p.byte(104); p.uint32(5); p.string("中文\n file")
        let frame = PacketWriter.frame(p.data)
        var framer = PacketFramer()
        XCTAssertEqual(try framer.append(Data(frame.prefix(2))).count, 0)
        XCTAssertEqual(try framer.append(Data(frame.dropFirst(2).prefix(3))).count, 0)
        XCTAssertEqual(try framer.append(Data(frame.dropFirst(5)) + frame), [p.data, p.data])
    }
    func testMalformedPacketsFailClosed() throws {
        var framer = PacketFramer()
        XCTAssertThrowsError(try framer.append(Data([0xff, 0xff, 0xff, 0xff])))
        var reader = PacketReader(data: Data([0,0,0,8,1]))
        XCTAssertThrowsError(try reader.bytes())
        var name = PacketReader(data: Data([0,0,0,1,0xff]))
        XCTAssertThrowsError(try name.string())
    }
    func testRealSubsystemListAndConcurrentRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: root.appendingPathComponent("中文 \" [*]?\nfile.txt"))
        let session = try await SFTPSession.open(Connection(fixture: true))
        let items = try await session.list(root.path)
        XCTAssertEqual(items.first?.name, "中文 \" [*]?\nfile.txt")
        async let a = session.attributes(items[0].path)
        async let b = session.canonical(root.path)
        let (attr, canonical) = try await (a, b)
        XCTAssertEqual(attr.size, 5); XCTAssertTrue(canonical.hasSuffix(root.lastPathComponent))
        let handle = try await session.openFile(root.appendingPathComponent("write.bin").path, flags: 2 | 8 | 32)
        try await session.write(handle, offset: 0, data: Data([0,1,2,255]))
        try await session.closeHandle(handle)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("write.bin")), Data([0,1,2,255]))
        await session.close()
    }
    func testNoOverwriteAndSymlinkRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), other = root.appendingPathComponent("other")
        try Data("keep".utf8).write(to: original); try Data("other".utf8).write(to: other)
        let session = try await SFTPSession.open(Connection(fixture: true))
        do { try await session.rename(other.path, to: original.path); XCTFail("Must not overwrite") } catch { }
        XCTAssertEqual(try String(contentsOf: original), "keep")
        let link = root.appendingPathComponent("link")
        try await session.symlink(original.path, at: link.path)
        let attrs = try await session.attributes(link.path); XCTAssertEqual(attrs.kind, .symlink)
        try await session.removeTree(link.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        await session.close()
    }
}
