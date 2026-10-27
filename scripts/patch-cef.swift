// Lowers CEF's 2 s wait before extension popups appear (arm64).
//
// CEF waits up to kNewBrowserInfoResponseTimeoutMs (2000 ms) for "new
// browser info" for every frame that is not part of a CEF browser; extension
// popups are such frames. The value is a compile-time constant, so this
// patches the instructions that load it. The constant (2,000,000 µs) occurs
// in many places, so the right one is found next to the only code that
// loads the string "disable-new-browser-info-timeout", which CEF checks just
// before it starts the timer (libcef/browser/browser_info_manager.cc).
//
// usage: swift patch-cef.swift <framework binary> [--check]
import Foundation

let originalMicros: UInt32 = 2_000_000
let patchedMicros: UInt32 = 150_000
let anchor = "disable-new-browser-info-timeout"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("patch-cef: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fail("usage: patch-cef.swift <binary> [--check]") }
let path = arguments[1]
let checkOnly = arguments.contains("--check")
guard var data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }

// The library's __TEXT segment starts at file offset 0 with vmaddr 0, so
// file offsets are addresses.
guard let anchorData = (anchor + "\0").data(using: .utf8),
      let stringRange = data.range(of: anchorData) else { fail("string \(anchor) not found") }
guard stringRange.lowerBound > 0, data[stringRange.lowerBound - 1] == 0 else { fail("ambiguous string match") }
let stringAddress = Int64(stringRange.lowerBound)

/// mov wN, #lo16 ; movk wN, #hi16, lsl #16
func movPair(_ words: UnsafeBufferPointer<UInt32>, _ index: Int) -> (register: UInt32, value: UInt32)? {
    let first = words[index], second = words[index + 1]
    guard first & 0xFFE0_0000 == 0x5280_0000, second & 0xFFE0_0000 == 0x72A0_0000,
          first & 0x1F == second & 0x1F else { return nil }
    return (first & 0x1F, ((second >> 5) & 0xFFFF) << 16 | ((first >> 5) & 0xFFFF))
}

var targets = Set<Int>()
var foundPair: (register: UInt32, value: UInt32)?
data.withUnsafeBytes { raw in
    let words = raw.bindMemory(to: UInt32.self)
    let count = words.count - 2
    for index in 0..<count {
        let instruction = words[index]
        guard instruction & 0x9F00_0000 == 0x9000_0000 else { continue }  // adrp xN, page
        let immlo = Int64((instruction >> 29) & 0x3)
        let immhi = Int64((instruction >> 5) & 0x7FFFF)
        var immediate = (immhi << 2 | immlo) << 12
        if immediate & (1 << 32) != 0 { immediate -= 1 << 33 }
        guard (Int64(index * 4) & ~0xFFF) + immediate == stringAddress & ~0xFFF else { continue }
        let register = instruction & 0x1F
        // add xN, xN, #pageoff shortly after.
        for step in 1...6 where index + step < count {
            let add = words[index + step]
            guard add & 0xFFC0_0000 == 0x9100_0000, (add >> 5) & 0x1F == register,
                  Int64((add >> 10) & 0xFFF) == stringAddress & 0xFFF else { continue }
            // The timer delay is loaded a few dozen instructions later.
            for scan in index..<min(count, index + 128) {
                if let pair = movPair(words, scan), pair.value == originalMicros || pair.value == patchedMicros {
                    targets.insert(scan * 4)
                    foundPair = pair
                    break
                }
            }
            break
        }
    }
}

guard targets.count == 1, let target = targets.first, let pair = foundPair else {
    fail("expected one timer delay next to \(anchor), found \(targets.count); update this script")
}
let location = "0x" + String(target, radix: 16)
if pair.value == patchedMicros {
    print("patch-cef: already patched at \(location)")
    exit(0)
}
if checkOnly {
    print("patch-cef: would patch \(location) (\(pair.value) µs -> \(patchedMicros) µs)")
    exit(0)
}
let mov = 0x5280_0000 | ((patchedMicros & 0xFFFF) << 5) | pair.register
let movk = 0x72A0_0000 | ((patchedMicros >> 16) << 5) | pair.register
data.withUnsafeMutableBytes { bytes in
    bytes.storeBytes(of: mov.littleEndian, toByteOffset: target, as: UInt32.self)
    bytes.storeBytes(of: movk.littleEndian, toByteOffset: target + 4, as: UInt32.self)
}
do {
    try data.write(to: URL(fileURLWithPath: path))
} catch {
    fail("cannot write \(path): \(error)")
}
print("patch-cef: extension popup delay 2000 ms -> \(patchedMicros / 1000) ms at \(location)")
