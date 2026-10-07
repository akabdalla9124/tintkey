import Foundation
import Darwin

// Blocking OpenRGB SDK client (TCP, default 127.0.0.1:6742), intended for use from a serial queue.
// Based on OpenRGB's public network-protocol documentation; independent clean-room code.
// Safety: this client never sends SAVEMODE (1102), profile save/load/delete, settings or plugin
// packets. Those ids are not defined in this module (see OpenRGBPacketID).

public final class OpenRGBClient {
    public static let clientName = "Tintkey"
    public var connectTimeout: TimeInterval = 1
    public var replyTimeout: TimeInterval = 2

    private var fd: Int32 = -1
    private let lock = NSLock()
    /// Negotiated protocol version (1...3) once connected.
    public private(set) var protocolVersion: UInt32 = 0
    public private(set) var devices: [OpenRGBDevice] = []

    public init() {}
    deinit { closeLocked() }

    public var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return fd >= 0 }

    // MARK: connection

    @discardableResult
    public func connect(host: String = "127.0.0.1", port: UInt16 = 6742) -> Bool {
        lock.lock(); defer { lock.unlock() }
        closeLocked()
        guard openSocket(host: host, port: port) else { return false }
        guard handshake() else { closeLocked(); return false }
        return true
    }

    public func close() { lock.lock(); closeLocked(); lock.unlock() }

    private func closeLocked() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        protocolVersion = 0; devices = []
    }

    private func openSocket(host: String, port: UInt16) -> Bool {
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return false }
        defer { freeaddrinfo(res) }
        let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard s >= 0 else { return false }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        let rc = Darwin.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        if rc != 0 {
            guard errno == EINPROGRESS, waitFor(s, events: Int16(POLLOUT), timeout: connectTimeout) else { Darwin.close(s); return false }
            var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { Darwin.close(s); return false }
        }
        fd = s
        return true
    }

    private func waitFor(_ s: Int32, events: Int16, timeout: TimeInterval) -> Bool {
        var p = pollfd(fd: s, events: events, revents: 0)
        let ms = Int32(max(0, min(timeout, 60)) * 1000)
        while true {
            let r = poll(&p, 1, ms)
            if r < 0 && errno == EINTR { continue }
            return r > 0 && (p.revents & events) != 0
        }
    }

    // MARK: low-level I/O (callers hold the lock)

    private func writeAll(_ data: [UInt8]) -> Bool {
        guard fd >= 0 else { return false }
        var off = 0
        while off < data.count {
            let n = data[off...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 { off += n; continue }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if waitFor(fd, events: Int16(POLLOUT), timeout: replyTimeout) { continue }
            }
            closeLocked(); return false
        }
        return true
    }

    private func readExactly(_ count: Int, deadline: Date) -> [UInt8]? {
        guard fd >= 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let remain = deadline.timeIntervalSinceNow
            guard remain > 0, waitFor(fd, events: Int16(POLLIN), timeout: remain) else { closeLocked(); return nil }
            let n = buf.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress! + got, count - got, 0) }
            if n > 0 { got += n; continue }
            if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            closeLocked(); return nil      // EOF or error
        }
        return buf
    }

    private func send(device: UInt32, id: UInt32, payload: [UInt8] = []) -> Bool {
        writeAll(OpenRGBWire.packet(device: device, id: id, payload: payload))
    }

    /// Reads packets until one with `id` arrives (unsolicited packets such as DEVICE_LIST_UPDATED are skipped).
    private func receive(id: UInt32) -> [UInt8]? {
        let deadline = Date().addingTimeInterval(replyTimeout)
        for _ in 0..<64 {
            guard let h = readExactly(16, deadline: deadline) else { return nil }
            guard let hdr = try? OpenRGBWire.parseHeader(h) else { closeLocked(); return nil }
            guard let body = hdr.size == 0 ? [] : readExactly(hdr.size, deadline: deadline) else { return nil }
            if hdr.id == id { return body }
        }
        return nil
    }

    // MARK: handshake and device data

    private func handshake() -> Bool {
        guard send(device: 0, id: OpenRGBPacketID.setClientName, payload: Array(Self.clientName.utf8) + [0]),
              send(device: 0, id: OpenRGBPacketID.requestProtocolVersion, payload: OpenRGBWire.le32(OpenRGBWire.maxProtocol)),
              let v = receive(id: OpenRGBPacketID.requestProtocolVersion), v.count >= 4 else { return false }
        var r = OpenRGBReader(v)
        guard let server = try? r.u32() else { return false }
        let negotiated = min(server, OpenRGBWire.maxProtocol)
        guard negotiated >= 1 else { return false }     // protocol 0 (no version reply) is not supported
        protocolVersion = negotiated
        return loadDevices()
    }

    private func loadDevices() -> Bool {
        guard send(device: 0, id: OpenRGBPacketID.requestControllerCount),
              let c = receive(id: OpenRGBPacketID.requestControllerCount) else { return false }
        var r = OpenRGBReader(c)
        guard let n = try? r.u32(), n < 1024 else { return false }
        var out: [OpenRGBDevice] = []
        for i in 0..<Int(n) {
            guard let d = fetchDevice(i) else { return false }
            out.append(d)
        }
        devices = out
        return true
    }

    private func fetchDevice(_ index: Int) -> OpenRGBDevice? {
        guard send(device: UInt32(index), id: OpenRGBPacketID.requestControllerData,
                   payload: OpenRGBWire.le32(protocolVersion)),
              let p = receive(id: OpenRGBPacketID.requestControllerData) else { return nil }
        var r = OpenRGBReader(p)
        guard let size = try? r.u32(), size >= 4, Int(size) <= p.count else { return nil }
        let block = Array(p[4..<Int(size)])
        return try? OpenRGBWire.parseDevice(block, index: index, version: protocolVersion)
    }

    /// Re-reads every controller from the server.
    @discardableResult
    public func refreshDevices() -> Bool { lock.lock(); defer { lock.unlock() }; return fd >= 0 && loadDevices() }

    // MARK: operations

    public func snapshot(device: Int) -> OpenRGBSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0, let d = fetchDevice(device) else { return nil }
        if let i = devices.firstIndex(where: { $0.index == device }) { devices[i] = d }
        return OpenRGBSnapshot(deviceIndex: device, activeMode: d.activeMode,
                               mode: d.modes.indices.contains(d.activeMode) ? d.modes[d.activeMode] : nil,
                               colors: d.currentColors)
    }

    /// SETCUSTOMMODE then UPDATELEDS with every LED the same color.
    public func setAll(device: Int, color: RGB) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0, let d = devices.first(where: { $0.index == device }), d.ledCount > 0 else { return false }
        return setCustomAndUpdate(device, [RGB](repeating: color, count: d.ledCount))
    }

    /// Per-key colors; `colors.count` must equal the device's LED count.
    public func setLEDs(device: Int, colors: [RGB]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0, let d = devices.first(where: { $0.index == device }),
              colors.count == d.ledCount, colors.count > 0, colors.count <= Int(UInt16.max) else { return false }
        return setCustomAndUpdate(device, colors)
    }

    private func setCustomAndUpdate(_ device: Int, _ colors: [RGB]) -> Bool {
        send(device: UInt32(device), id: OpenRGBPacketID.setCustomMode)
            && send(device: UInt32(device), id: OpenRGBPacketID.updateLEDs, payload: OpenRGBWire.updateLEDsPayload(colors))
    }

    /// Re-sends the saved colors, then re-selects the saved mode (UPDATEMODE) if the live mode differs.
    public func restore(device: Int, snapshot s: OpenRGBSnapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0, s.deviceIndex == device else { return false }
        let live = fetchDevice(device)
        guard fd >= 0 else { return false }
        if let live, live.ledCount != s.colors.count { return false }
        var ok = true
        if !s.colors.isEmpty, s.colors.count <= Int(UInt16.max) {
            ok = send(device: UInt32(device), id: OpenRGBPacketID.updateLEDs, payload: OpenRGBWire.updateLEDsPayload(s.colors))
        }
        // If we could not read the live state, re-select the mode to be safe.
        let needsMode = live.map { $0.activeMode != s.activeMode } ?? true
        if ok, needsMode, let m = s.mode {
            ok = send(device: UInt32(device), id: OpenRGBPacketID.updateMode,
                      payload: OpenRGBWire.updateModePayload(index: m.index, raw: m.raw))
        }
        return ok
    }
}
