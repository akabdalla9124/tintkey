import XCTest
import Darwin
@testable import TintkeyKit

// In-process fake OpenRGB server speaking the documented protocol (v1-3 layouts). No hardware, no OpenRGB.

private func le32(_ v: UInt32) -> [UInt8] { OpenRGBWire.le32(v) }
private func le16(_ v: UInt16) -> [UInt8] { OpenRGBWire.le16(v) }
private func str(_ s: String) -> [UInt8] { le16(UInt16(s.utf8.count + 1)) + Array(s.utf8) + [0] }

private func modeBlock(_ name: String, flags: UInt32, colorMode: UInt32, version: UInt32) -> [UInt8] {
    var b = str(name) + le32(0) + le32(flags) + le32(0) + le32(0)
    if version >= 3 { b += le32(0) + le32(100) }
    b += le32(0) + le32(0) + le32(0)
    if version >= 3 { b += le32(50) }
    b += le32(0) + le32(colorMode) + le16(0)
    return b
}

func cannedKeyboardBlock(version: UInt32, active: Int32 = 1, colors: [RGB]? = nil) -> [UInt8] {
    let cols = colors ?? (0..<10).map { RGB(r: UInt8($0 + 1), g: UInt8($0 * 2), b: 200) }
    var b = le32(5) + str("Test Keyboard") + str("ACME") + str("Keyboard device") + str("1.0") + str("SN1") + str("HID: /dev/x")
    b += le16(3) + le32(UInt32(bitPattern: active))
    b += modeBlock("Direct", flags: 1 << 5, colorMode: 1, version: version)
    b += modeBlock("Static", flags: 1 << 6, colorMode: 2, version: version)
    b += modeBlock("Breathing", flags: 1 | 1 << 6, colorMode: 2, version: version)
    b += le16(3)
    for (n, c) in [("Left", 4), ("Mid", 4), ("Right", 2)] {
        b += str(n) + le32(1) + le32(0) + le32(UInt32(c)) + le32(UInt32(c)) + le16(0)
    }
    b += le16(10)
    for i in 0..<10 { b += str("Key \(i)") + le32(UInt32(i)) }
    b += OpenRGBWire.colorBlock(cols)
    return b
}

struct Received { var dev: UInt32; var id: UInt32; var payload: [UInt8] }

final class FakeServer {
    enum Fault { case none, truncateData, garbageData, closeMidReply }
    let listenFD: Int32
    let port: UInt16
    var serverVersion: UInt32 = 5
    var fault: Fault = .none
    var activeMode: Int32 = 1
    private let lock = NSLock()
    private var _received: [Received] = []
    var received: [Received] { lock.lock(); defer { lock.unlock() }; return _received }
    private var conn: Int32 = -1

    init() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, 4)
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = 0
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 1)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        listenFD = fd
        port = UInt16(bigEndian: a.sin_port)
    }

    func start() { Thread.detachNewThread { [self] in serve() } }
    func stop() { if conn >= 0 { Darwin.close(conn) }; Darwin.close(listenFD) }

    private func readN(_ n: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n); var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { recv(conn, $0.baseAddress! + got, n - got, 0) }
            if r <= 0 { return nil }; got += r
        }
        return buf
    }
    private func write(_ d: [UInt8]) { _ = d.withUnsafeBytes { Darwin.send(conn, $0.baseAddress, $0.count, 0) } }

    private func serve() {
        conn = accept(listenFD, nil, nil)
        guard conn >= 0 else { return }
        var negotiated: UInt32 = 0
        while let h = readN(16), let hdr = try? OpenRGBWire.parseHeader(h), let p = hdr.size == 0 ? [] : readN(hdr.size) {
            lock.lock(); _received.append(Received(dev: hdr.device, id: hdr.id, payload: p)); lock.unlock()
            switch hdr.id {
            case 40:
                negotiated = min(serverVersion, le(p))
                write(OpenRGBWire.packet(device: 0, id: 40, payload: le32(serverVersion)))
            case 0:
                // unsolicited packet first, which the client must skip
                write(OpenRGBWire.packet(device: 0, id: 100))
                write(OpenRGBWire.packet(device: 0, id: 0, payload: le32(1)))
            case 1:
                var blk = cannedKeyboardBlock(version: negotiated, active: activeMode)
                switch fault {
                case .none: break
                case .truncateData: blk = Array(blk.prefix(blk.count / 2))
                case .garbageData: blk = (0..<blk.count).map { UInt8(truncatingIfNeeded: $0 &* 197 &+ 255) }
                case .closeMidReply:
                    let full = OpenRGBWire.packet(device: hdr.device, id: 1, payload: le32(UInt32(blk.count + 4)) + blk)
                    write(Array(full.prefix(full.count / 2))); Darwin.close(conn); conn = -1; return
                }
                write(OpenRGBWire.packet(device: hdr.device, id: 1, payload: le32(UInt32(blk.count + 4)) + blk))
            case 1100:
                activeMode = 0
            case 1101:
                if p.count >= 8 { activeMode = Int32(bitPattern: le(Array(p[4..<8]))) }
            default: break
            }
        }
    }
    private func le(_ p: [UInt8]) -> UInt32 { var r = OpenRGBReader(p); return (try? r.u32()) ?? 0 }
}

final class OpenRGBClientTests: XCTestCase {
    private func make(_ configure: (FakeServer) -> Void = { _ in }) -> (FakeServer, OpenRGBClient) {
        let s = FakeServer(); configure(s); s.start()
        let c = OpenRGBClient(); c.replyTimeout = 1
        return (s, c)
    }

    func testHandshakeAndDeviceParsing() {
        let (s, c) = make(); defer { c.close(); s.stop() }
        XCTAssertTrue(c.connect(port: s.port))
        XCTAssertTrue(c.isConnected)
        XCTAssertEqual(c.protocolVersion, 3, "server speaks 5, we cap at 3")
        let r = s.received
        XCTAssertEqual(r.map(\.id), [50, 40, 0, 1])
        XCTAssertEqual(r[0].payload, Array("Tintkey".utf8) + [0])
        XCTAssertEqual(r[1].payload, le32(3))
        XCTAssertEqual(r[3].payload, le32(3))
        let d = try! XCTUnwrap(c.devices.first)
        XCTAssertEqual(d.name, "Test Keyboard"); XCTAssertEqual(d.vendor, "ACME"); XCTAssertEqual(d.type, .keyboard)
        XCTAssertEqual(d.location, "HID: /dev/x")
        XCTAssertEqual(d.ledCount, 10); XCTAssertEqual(d.zones.map(\.ledCount), [4, 4, 2])
        XCTAssertEqual(d.modes.map(\.name), ["Direct", "Static", "Breathing"])
        XCTAssertTrue(d.hasDirectMode); XCTAssertTrue(d.hasStaticMode); XCTAssertFalse(d.hasCustomMode)
        XCTAssertTrue(d.modes[0].supportsPerLEDColor)
        XCTAssertEqual(d.activeMode, 1)
        XCTAssertEqual(d.currentColors.count, 10); XCTAssertEqual(d.currentColors[3], RGB(r: 4, g: 6, b: 200))
    }

    func testLowerServerVersionIsUsed() {
        let (s, c) = make { $0.serverVersion = 2 }; defer { c.close(); s.stop() }
        XCTAssertTrue(c.connect(port: s.port))
        XCTAssertEqual(c.protocolVersion, 2)
        XCTAssertEqual(c.devices.first?.modes.map(\.name), ["Direct", "Static", "Breathing"])
    }

    func testSetAllSendsExpectedPacketsInOrder() {
        let (s, c) = make(); defer { c.close(); s.stop() }
        XCTAssertTrue(c.connect(port: s.port))
        XCTAssertTrue(c.setAll(device: 0, color: RGB(r: 1, g: 2, b: 3)))
        // a round-trip request flushes ordering: server handles packets sequentially
        XCTAssertNotNil(c.snapshot(device: 0))
        let sent = s.received.dropFirst(4)
        XCTAssertEqual(Array(sent.map(\.id).prefix(3)), [1100, 1050, 1])
        let led = Array(sent)[1]
        XCTAssertEqual(led.dev, 0)
        XCTAssertEqual(led.payload.count, 4 + 2 + 40)
        XCTAssertEqual(Array(led.payload[0..<4]), le32(46))
        XCTAssertEqual(Array(led.payload[4..<6]), le16(10))
        XCTAssertEqual(Array(led.payload[6..<10]), [1, 2, 3, 0])
        XCTAssertEqual(Array(led.payload[42..<46]), [1, 2, 3, 0])
    }

    func testSetLEDsValidatesCount() {
        let (s, c) = make(); defer { c.close(); s.stop() }
        XCTAssertTrue(c.connect(port: s.port))
        XCTAssertFalse(c.setLEDs(device: 0, colors: [RGB(r: 1, g: 1, b: 1)]))
        XCTAssertFalse(c.setAll(device: 5, color: RGB(r: 1, g: 1, b: 1)))
        XCTAssertTrue(c.setLEDs(device: 0, colors: (0..<10).map { RGB(r: UInt8($0), g: 0, b: 0) }))
    }

    func testRestoreResendsColorsAndMode() {
        let (s, c) = make(); defer { c.close(); s.stop() }
        XCTAssertTrue(c.connect(port: s.port))
        let snap = try! XCTUnwrap(c.snapshot(device: 0))
        XCTAssertEqual(snap.activeMode, 1); XCTAssertEqual(snap.mode?.name, "Static")
        XCTAssertTrue(c.setAll(device: 0, color: RGB(r: 9, g: 9, b: 9)))   // server switches to mode 0
        XCTAssertNotNil(c.snapshot(device: 0))   // round-trip so the server has processed everything so far
        let before = s.received.count
        XCTAssertTrue(c.restore(device: 0, snapshot: snap))
        XCTAssertNotNil(c.snapshot(device: 0))
        let after = Array(s.received.dropFirst(before))
        XCTAssertEqual(after.map(\.id), [1, 1050, 1101, 1])
        guard after.count == 4 else { return }
        XCTAssertEqual(Array(after[1].payload[6..<10]), [1, 0, 200, 0])
        XCTAssertEqual(Array(after[2].payload[4..<8]), le32(1))
        XCTAssertEqual(Array(after[2].payload[8...]), snap.mode!.raw)
        XCTAssertEqual(s.activeMode, 1)
    }

    func testRestoreSkipsModeWhenUnchanged() {
        let (s, c) = make(); defer { c.close(); s.stop() }
        XCTAssertTrue(c.connect(port: s.port))
        let snap = try! XCTUnwrap(c.snapshot(device: 0))
        let before = s.received.count
        XCTAssertTrue(c.restore(device: 0, snapshot: snap))
        XCTAssertNotNil(c.snapshot(device: 0))
        XCTAssertEqual(s.received.dropFirst(before).map(\.id), [1, 1050, 1])
    }

    func testNeverSendsSaveMode() {
        let (s, c) = make(); defer { c.close(); s.stop() }
        XCTAssertTrue(c.connect(port: s.port))
        let snap = c.snapshot(device: 0)!
        _ = c.setAll(device: 0, color: RGB(r: 1, g: 1, b: 1)); _ = c.restore(device: 0, snapshot: snap)
        _ = c.snapshot(device: 0)
        let ids = Set(s.received.map(\.id))
        XCTAssertFalse(ids.contains(1102))
        XCTAssertTrue(ids.isSubset(of: [0, 1, 40, 50, 1050, 1100, 1101]))
    }

    func testTruncatedAndGarbageBlobsRejected() {
        let good = cannedKeyboardBlock(version: 3)
        XCTAssertNoThrow(try OpenRGBWire.parseDevice(good, index: 0, version: 3))
        for n in 0..<good.count {
            XCTAssertThrowsError(try OpenRGBWire.parseDevice(Array(good.prefix(n)), index: 0, version: 3), "prefix \(n)")
        }
        var seed: UInt32 = 12345
        for _ in 0..<500 {   // random garbage must never trap
            let junk = (0..<Int.random(in: 0..<300)).map { _ -> UInt8 in seed = seed &* 1664525 &+ 1013904223; return UInt8(seed >> 24) }
            _ = try? OpenRGBWire.parseDevice(junk, index: 0, version: 3)
        }
        // oversized length prefix
        var bad = good; bad[4] = 0xFF; bad[5] = 0xFF
        XCTAssertThrowsError(try OpenRGBWire.parseDevice(bad, index: 0, version: 3))
        XCTAssertThrowsError(try OpenRGBWire.parseDevice(good, index: 0, version: 0))
        XCTAssertThrowsError(try OpenRGBWire.parseDevice(good, index: 0, version: 6))
    }

    func testServerSideTruncatedAndGarbageDataFailConnect() {
        for f in [FakeServer.Fault.truncateData, .garbageData] {
            let (s, c) = make { $0.fault = f }
            XCTAssertFalse(c.connect(port: s.port), "\(f)")
            XCTAssertFalse(c.isConnected)
            c.close(); s.stop()
        }
    }

    func testServerClosingMidReply() {
        let (s, c) = make { $0.fault = .closeMidReply }; defer { s.stop() }
        XCTAssertFalse(c.connect(port: s.port))
        XCTAssertFalse(c.isConnected)
        XCTAssertFalse(c.setAll(device: 0, color: RGB(r: 1, g: 1, b: 1)))
        XCTAssertNil(c.snapshot(device: 0))
    }

    func testServerDisconnectAfterConnectDoesNotCrash() {
        let (s, c) = make(); defer { c.close() }
        XCTAssertTrue(c.connect(port: s.port))
        s.stop()
        _ = c.setAll(device: 0, color: RGB(r: 1, g: 1, b: 1))
        _ = c.setAll(device: 0, color: RGB(r: 1, g: 1, b: 1))
        XCTAssertNil(c.snapshot(device: 0))
        XCTAssertFalse(c.isConnected)
    }

    func testConnectRefused() {
        let s = FakeServer(); let port = s.port; s.stop()
        XCTAssertFalse(OpenRGBClient().connect(port: port))
    }

    func testHeaderValidation() {
        XCTAssertThrowsError(try OpenRGBWire.parseHeader(Array("XXXX".utf8) + [UInt8](repeating: 0, count: 12)))
        XCTAssertThrowsError(try OpenRGBWire.parseHeader(Array("ORGB".utf8) + le32(0) + le32(0) + le32(0xFFFFFFFF)))
        XCTAssertEqual(OpenRGBWire.packet(device: 2, id: 1050, payload: [9]),
                       Array("ORGB".utf8) + [2, 0, 0, 0, 0x1A, 0x04, 0, 0, 1, 0, 0, 0, 9])
    }
}
