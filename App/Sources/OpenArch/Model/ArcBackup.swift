import Foundation

/// "Arc-Daten sichern": Arc's own JSON files (the sidebar, spaces, settings)
/// and its `Local State` (profiles) as one zip file in ~/Documents. Arc ends
/// on 22 December 2026; with this the sidebar can still be imported later.
/// Arc's folder is only read.
enum ArcBackup {
    static let arcFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Arc")

    static var isAvailable: Bool {
        !files(in: arcFolder).isEmpty
    }

    enum BackupError: LocalizedError {
        case nothingFound, zipFailed
        var errorDescription: String? {
            switch self {
            case .nothingFound: "In Arcs Ordner wurden keine Daten zum Sichern gefunden."
            case .zipFailed: "Die ZIP-Datei konnte nicht geschrieben werden."
            }
        }
    }

    /// The files to back up, relative to |folder|.
    static func files(in folder: URL) -> [String] {
        let fm = FileManager.default
        var files = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted()
        if fm.fileExists(atPath: folder.appendingPathComponent("User Data/Local State").path) {
            files.append("User Data/Local State")
        }
        return files
    }

    /// Writes "Arc-Sicherung <date>.zip" into |destination| and returns it.
    @discardableResult
    static func make(from folder: URL = arcFolder,
                     into destination: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
                     date: Date = Date()) throws -> URL {
        let files = files(in: folder)
        guard !files.isEmpty else { throw BackupError.nothingFound }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        var target = destination.appendingPathComponent("Arc-Sicherung \(formatter.string(from: date)).zip")
        var index = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = destination.appendingPathComponent("Arc-Sicherung \(formatter.string(from: date)) \(index).zip")
            index += 1
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = folder
        zip.arguments = ["-q", "-X", target.path] + files
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0, FileManager.default.fileExists(atPath: target.path) else { throw BackupError.zipFailed }
        return target
    }
}
