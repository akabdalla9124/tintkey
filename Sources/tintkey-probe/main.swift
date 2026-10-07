import Foundation
import TintkeyKit

// tintkey-probe [--all]
//   tintkey-probe --set <hue 0-255> <sat 0-255> [--keep]
//     Sets the live rgb_matrix color, verifies by reading it back, then restores the previous
//     color after 3s unless --keep. Never saves to EEPROM.
//   Lists HID devices that expose the VIA/QMK raw HID interface (usage page 0xFF60 / 0x61),
//   then does READ-ONLY queries: VIA protocol version and current lighting values.
//   --all also lists every other HID interface (useful if your board doesn't show up).

let showAll = CommandLine.arguments.contains("--all")
let all = showAll ? HIDScanner.scan() : []
if showAll && all.isEmpty {
    print("Couldn't list all HID interfaces (IOKit status 0x\(String(UInt32(bitPattern: HIDScanner.lastStatus), radix: 16))).")
    print("Grant Input Monitoring to your terminal in System Settings > Privacy & Security, or skip --all.\n")
}
let raw = HIDScanner.rawHIDDevices()

func line(_ d: HIDDeviceInfo) -> String {
    String(format: "  %@  %@ / %@  [%@]  usagePage=0x%04X usage=0x%02X", d.idString, d.manufacturer, d.product, d.transport, d.usagePage, d.usage)
}

if showAll {
    print("All HID interfaces (\(all.count)):")
    all.forEach { print(line($0)) }
    print()
}

guard !raw.isEmpty else {
    print("No raw HID (VIA/QMK) interfaces found.")
    print("• Is the keyboard plugged in, or the 2.4GHz dongle inserted with the board in 2.4G mode?")
    print("• Run with --all to see everything macOS exposes.")
    exit(1)
}

print("Raw HID interfaces (\(raw.count)):")
for d in raw {
    print(line(d))
    let via = VIAClient(d)
    if let v = via.protocolVersion() {
        print(String(format: "    VIA protocol version: 0x%04X", v))
        for (name, ch) in [("rgb_matrix", VIAClient.Channel.rgbMatrix), ("rgblight", .rgblight), ("backlight", .backlight)] {
            let b = via.lighting(ch, .brightness).map { "\($0[0])" } ?? "-"
            let e = via.lighting(ch, .effect).map { "\($0[0])" } ?? "-"
            let c = via.lighting(ch, .color).map { "hue=\($0[0]) sat=\($0.count > 1 ? Int($0[1]) : 0)" } ?? "-"
            print("    \(name): brightness=\(b) effect=\(e) color=\(c)")
        }
    } else {
        print("    No VIA reply (not VIA firmware, locked, or the wireless link doesn't forward raw HID).")
    }
}

// MARK: --set
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--set") {
    guard args.count > i + 2, let h = UInt8(args[i + 1]), let sat = UInt8(args[i + 2]) else {
        print("usage: tintkey-probe --set <hue 0-255> <sat 0-255> [--keep]")
        exit(2)
    }
    let keep = args.contains("--keep")
    guard let d = raw.first else { exit(1) }
    let via = VIAClient(d)
    guard let prev = via.lighting(.rgbMatrix, .color), prev.count >= 2 else {
        print("Couldn't read the current color; refusing to write."); exit(1)
    }
    print("\nSetting rgb_matrix color hue=\(h) sat=\(sat) (was hue=\(prev[0]) sat=\(prev[1]))")
    let got = via.setColor(.rgbMatrix, hue: h, saturation: sat)
    var ok = false
    if let got = got {
        ok = got.hue == h && got.sat == sat
        print("  readback hue=\(got.hue) sat=\(got.sat) \(ok ? "OK" : "MISMATCH (effect may not use a single color)")")
    } else {
        print("  FAIL: no acknowledgement or readback (the write may still have applied).")
    }
    // Restore even after a failed readback, since the write may have gone through.
    if !keep {
        print("  restoring in 3s...")
        Thread.sleep(forTimeInterval: 3)
        if let back = via.setColor(.rgbMatrix, hue: prev[0], saturation: prev[1]) {
            let restored = back.hue == prev[0] && back.sat == prev[1]
            print("  restored hue=\(back.hue) sat=\(back.sat) \(restored ? "OK" : "MISMATCH")")
            ok = ok && restored
        } else {
            print("  FAIL: restore not confirmed; original was hue=\(prev[0]) sat=\(prev[1]).")
            ok = false
        }
    }
    exit(ok ? 0 : 1)
}

// MARK: --brightness
if let i = args.firstIndex(of: "--brightness") {
    guard args.count > i + 1, let level = UInt8(args[i + 1]), let d = raw.first else {
        print("usage: tintkey-probe --brightness <0-255>"); exit(2)
    }
    let ok = VIAClient(d).setBrightness(.rgbMatrix, level)
    print("\nbrightness \(level): \(ok ? "OK" : "FAILED")")
    exit(ok ? 0 : 1)
}

// MARK: --kc-probe (read-only Keychron command survey; sends no set/save commands)
if args.contains("--kc-probe") {
    guard let d = raw.first else { exit(1) }
    let via = VIAClient(d)
    func hex(_ b: [UInt8]?, _ n: Int = 20) -> String { b.map { $0.prefix(n).map { String(format: "%02X", $0) }.joined(separator: " ") } ?? "no reply" }
    print("\nKeychron survey on \(d.idString)")
    print("A0 protocol      :", hex(via.request([0xA0])))
    if let r = via.request([0xA1]) { print("A1 firmware      :", String(decoding: r.dropFirst().prefix(while: { $0 != 0 }), as: UTF8.self), "|", hex(r, 12)) } else { print("A1 firmware      : no reply") }
    print("A2 features      :", hex(via.request([0xA2])), "(per-key bit is 0x80 in the feature byte)")
    print("A8 01 rgb version:", hex(via.request([0xA8, 0x01])))
    print("A8 05 led count  :", hex(via.request([0xA8, 0x05])))
    print("A8 07 per-key typ:", hex(via.request([0xA8, 0x07])))
    print("VIA effect id    :", hex(via.request([0x08, 0x03, 0x02])))
    for r in 0..<6 { print("A8 06 row \(r)     :", hex(via.request([0xA8, 0x06, UInt8(r), 0xFF, 0xFF, 0xFF]), 19)) }
    var n = 0
    for s in stride(from: 0, to: 81, by: 9) {
        guard let r = via.request([0xA8, 0x09, UInt8(s), 9]), r.count >= 30, r[2] == 0 else { print("A8 09 start \(s): failed (\(hex(via.request([0xA8, 0x09, UInt8(s), 9]), 6)))"); continue }
        n += 1
        if s == 0 { print("A8 09 colors LED0-8 (H S V triples):", hex(r, 30)) }
    }
    print("A8 09 baseline chunks read: \(n)/9")
    exit(0)
}
