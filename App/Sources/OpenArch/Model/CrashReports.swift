import AppKit
import OpenArchLocalization
import Darwin
import OpenArchCore

/// Crash reports, only ever sent by hand. OpenArch notes three things in
/// CrashReports/ in its data folder:
///
/// - its own crash: a signal handler writes the signal's number to a file,
///   since macOS does not always write a report for a process this big;
/// - a tab's renderer that ended unexpectedly (CEF's OnRenderProcessTerminated);
/// - macOS's crash reports (.ips in ~/Library/Logs/DiagnosticReports) of
///   this copy of OpenArch and its helpers: the app, renderers, the GPU
///   process and the utility processes. CEF tells the app of no other
///   process's end, so these are how a GPU or network crash shows.
///
/// At the next launch OpenArch asks whether to send a report, and shows it.
/// "Bericht senden" opens a new GitHub issue with the report filled in, to
/// send from there; nothing goes anywhere by itself. A report has the
/// versions, the kind of process, how it ended and the function names of
/// the crashing thread: never addresses, titles, paths or page content.
@MainActor
final class CrashReports {
    struct Event: Codable, Equatable {
        var date: Date
        /// "App", "Renderer", "GPU", "Utility", "Plugin" or "Alerts".
        var process: String
        /// How it ended: "SIGSEGV", "crashed (exit code 11)",
        /// "EXC_BAD_ACCESS (SIGSEGV)" …
        var kind: String
        /// The crashing thread's top frames: "<binary> <function>".
        var frames: [String] = []
        /// "ips", "signal" or "renderer".
        var source: String
    }

    static let shared = CrashReports(folder: AppPaths.support.appendingPathComponent("CrashReports", isDirectory: true))
    static let issueURL = "https://github.com/dpfaffenbauer/OpenArch/issues/new"
    static let maxPending = 20

    let folder: URL
    /// Where macOS keeps crash reports; the self-test uses its own.
    var diagnosticReports = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    /// Only reports of processes inside this bundle count.
    var bundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
    /// The self-test's instance leaves the setting alone.
    var persistsSetting = true
    private var enabledInMemory = true

    /// Settings › Info › Absturzberichte: whether OpenArch notes crashes
    /// and asks after one.
    var isEnabled: Bool {
        get { persistsSetting ? UserDefaults.standard.object(forKey: "crashReports") as? Bool ?? true : enabledInMemory }
        set {
            if persistsSetting { UserDefaults.standard.set(newValue, forKey: "crashReports") } else { enabledInMemory = newValue }
            if !newValue { discardPending() }
        }
    }

    init(folder: URL) {
        self.folder = folder
    }

    private var pendingFile: URL { folder.appendingPathComponent("pending.json") }
    private var stateFile: URL { folder.appendingPathComponent("state.json") }
    var signalFile: URL { folder.appendingPathComponent("signal") }
    private var lastRendererEvent: Date?

    // MARK: Collecting

    /// At launch: this OpenArch's crash since the last launch and macOS's
    /// reports since the last look, added to the pending ones.
    func collectAtLaunch(now: Date = Date()) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let signalEvent = takeSignalRecord()
        guard isEnabled else { return }
        // The first look starts now: older reports are not this OpenArch's business.
        let since = (try? JSONDecoder.iso.decode([String: Date].self, from: Data(contentsOf: stateFile)))?["lastScan"] ?? now
        var events = scanDiagnosticReports(since: since)
        if let signalEvent,
           !events.contains(where: { $0.process == "App" && abs($0.date.timeIntervalSince(signalEvent.date)) < 300 }) {
            events.append(signalEvent)
        }
        try? JSONEncoder.iso.encode(["lastScan": now]).write(to: stateFile, options: .atomic)
        add(events)
    }

    /// A tab's renderer ended unexpectedly (OACPane.renderProcessGoneHandler).
    /// One event for all the tabs one renderer served.
    func rendererGone(status: String, code: Int32, now: Date = Date()) {
        guard isEnabled else { return }
        if let last = lastRendererEvent, now.timeIntervalSince(last) < 2 { return }
        lastRendererEvent = now
        add([Event(date: now, process: "Renderer", kind: "\(status) (exit code \(code))", source: "renderer")])
    }

    var pending: [Event] {
        (try? JSONDecoder.iso.decode([Event].self, from: Data(contentsOf: pendingFile))) ?? []
    }

    func discardPending() {
        try? FileManager.default.removeItem(at: pendingFile)
    }

    private func add(_ events: [Event]) {
        guard !events.isEmpty else { return }
        var all = pending
        for event in events {
            // macOS's report of a renderer crash that CEF reported too: the richer one.
            if event.source == "ips", event.process == "Renderer",
               let index = all.firstIndex(where: { $0.source == "renderer" && abs($0.date.timeIntervalSince(event.date)) < 120 }) {
                all[index] = event
            } else {
                all.append(event)
            }
        }
        all.sort { $0.date < $1.date }
        if all.count > Self.maxPending { all.removeFirst(all.count - Self.maxPending) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder.iso.encode(all).write(to: pendingFile, options: .atomic)
    }

    /// The signal handler's file from a crash of the last run, read and removed.
    private func takeSignalRecord() -> Event? {
        guard let data = try? Data(contentsOf: signalFile), let number = data.first else { return nil }
        let date = (try? signalFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        try? FileManager.default.removeItem(at: signalFile)
        return Event(date: date, process: "App", kind: Self.signalName(Int32(number)), source: "signal")
    }

    static func signalName(_ number: Int32) -> String {
        switch number {
        case SIGSEGV: "SIGSEGV"
        case SIGBUS: "SIGBUS"
        case SIGILL: "SIGILL"
        case SIGFPE: "SIGFPE"
        case SIGABRT: "SIGABRT"
        case SIGTRAP: "SIGTRAP"
        default: "signal \(number)"
        }
    }

    /// macOS's crash reports of this OpenArch, written since |since|.
    func scanDiagnosticReports(since: Date) -> [Event] {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: diagnosticReports.path) else { return [] }
        return names.filter { $0.hasPrefix("OpenArch") && $0.hasSuffix(".ips") }.compactMap { name in
            let url = diagnosticReports.appendingPathComponent(name)
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date > since, let text = try? String(contentsOf: url, encoding: .utf8),
                  var event = Self.parseIPS(text, bundlePath: bundlePath) else { return nil }
            event.date = date
            return event
        }
    }

    /// A macOS crash report (.ips: a line of JSON, then the report as JSON),
    /// reduced to what a crash report of OpenArch's may show. nil when it is
    /// no crash, or of a process outside |bundlePath|.
    static func parseIPS(_ text: String, bundlePath: String) -> Event? {
        guard let newline = text.firstIndex(of: "\n"),
              let header = try? JSONSerialization.jsonObject(with: Data(text[..<newline].utf8)) as? [String: Any],
              "\(header["bug_type"] ?? "")" == "309",
              let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: newline)...].utf8)) as? [String: Any],
              let path = body["procPath"] as? String, path.hasPrefix(bundlePath + "/"),
              let name = body["procName"] as? String else { return nil }
        let exception = body["exception"] as? [String: Any]
        var kind = exception?["type"] as? String ?? "crash"
        if let signal = exception?["signal"] as? String { kind += " (\(signal))" }
        var frames: [String] = []
        let images = body["usedImages"] as? [[String: Any]] ?? []
        if let threads = body["threads"] as? [[String: Any]], let faulting = body["faultingThread"] as? Int,
           threads.indices.contains(faulting) {
            for frame in (threads[faulting]["frames"] as? [[String: Any]] ?? []).prefix(12) {
                let index = frame["imageIndex"] as? Int ?? -1
                let image = images.indices.contains(index) ? images[index]["name"] as? String ?? "?" : "?"
                let offset = frame["imageOffset"] as? Int ?? 0
                frames.append("\(image) \(frame["symbol"] as? String ?? String(format: "+0x%x", offset))")
            }
        }
        return Event(date: Date(), process: processKind(name), kind: kind, frames: frames, source: "ips")
    }

    /// "OpenArch Helper (GPU)" → "GPU"; the plain helper runs the utility
    /// processes (network, storage, audio).
    static func processKind(_ name: String) -> String {
        if name == "OpenArch" { return "App" }
        if let open = name.firstIndex(of: "("), let close = name.lastIndex(of: ")"), open < close {
            return String(name[name.index(after: open)..<close])
        }
        return name.hasPrefix("OpenArch Helper") ? "Utility" : name
    }

    // MARK: The report

    func reportText(_ events: [Event], updater: Updater = .shared) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = [
            "OpenArch \(updater.versionDescription), \(updater.channel.title) channel",
            "Chromium \(OACEngine.versionString)",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "",
        ]
        let formatter = ISO8601DateFormatter()
        for event in events {
            lines.append("### \(event.process): \(event.kind)")
            lines.append(formatter.string(from: event.date))
            if !event.frames.isEmpty {
                lines.append("```")
                lines += event.frames
                lines.append("```")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// A new issue with the report, short enough for an address GitHub takes.
    func issueURL(for events: [Event]) -> URL? {
        var events = events
        while true {
            let first = events.first
            let title = "Crash: \(first?.process ?? "OpenArch") \(first?.kind ?? "")"
                + (events.count > 1 ? " (+\(events.count - 1) more)" : "")
            var components = URLComponents(string: Self.issueURL)
            components?.queryItems = [URLQueryItem(name: "title", value: title),
                                      URLQueryItem(name: "body", value: reportText(events))]
            guard let url = components?.url else { return nil }
            if url.absoluteString.count < 7500 || events.count <= 1 { return url }
            events.removeFirst()
        }
    }

    /// At launch: asks whether to send a report of the crashes since the
    /// last launch, and forgets them either way.
    func offer(open: (URL) -> Void) {
        let events = pending
        guard isEnabled, !events.isEmpty else { return }
        discardPending()
        let alert = NSAlert()
        alert.messageText = events.contains { $0.process == "App" }
            ? L("OpenArch ist abgestürzt") : L("Ein Teil von OpenArch ist abgestürzt")
        alert.informativeText = L("""
            Seit dem letzten Start hat sich OpenArch oder einer seiner Prozesse %@ \
            unerwartet beendet. Ein Bericht hilft, den Fehler zu finden. Er enthält nur Versionen und die Stelle im Code, \
            keine Adressen, Titel oder Seiteninhalte, und öffnet sich als Issue auf GitHub, wo du ihn vor dem Senden siehst.
            """, events.count == 1 ? L("einmal") : L("%lld-mal", events.count))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
        text.string = reportText(events)
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll
        alert.addButton(withTitle: L("Bericht senden …"))
        alert.addButton(withTitle: L("Nicht senden"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Nicht mehr nach Abstürzen fragen")
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { isEnabled = false }
        if answer == .alertFirstButtonReturn, let url = issueURL(for: events) { open(url) }
    }

    // MARK: The signal handler

    /// Notes OpenArch's own crash in |signalFile|, then lets the signal take
    /// its course (Chromium's handler, if it had one, or macOS's report).
    func installSignalHandlers() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        crashSignalPath = strdup(signalFile.path)
        for signal in crashSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = crashSignalHandler
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(signal, &action, previousSignalActions.advanced(by: Int(signal)))
        }
    }
}

private let crashSignals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP]
nonisolated(unsafe) private var crashSignalPath: UnsafeMutablePointer<CChar>?
nonisolated(unsafe) private let previousSignalActions: UnsafeMutablePointer<sigaction> = {
    let actions = UnsafeMutablePointer<sigaction>.allocate(capacity: 32)
    actions.initialize(repeating: sigaction(), count: 32)
    return actions
}()

/// Only async-signal-safe calls: open, write, close, sigaction, raise.
private func crashSignalHandler(_ signal: Int32) {
    if let path = crashSignalPath {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            var byte = UInt8(truncatingIfNeeded: signal)
            _ = write(fd, &byte, 1)
            close(fd)
        }
    }
    sigaction(signal, previousSignalActions.advanced(by: Int(signal)), nil)
    raise(signal)
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
