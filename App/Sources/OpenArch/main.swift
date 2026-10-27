import AppKit
import OpenArchCore

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments
AppPaths.isSelfTest = arguments.contains("--selftest")

guard OACEngine.loadFramework() else {
    fatalError("Could not load the Chromium Embedded Framework")
}

// Must exist before CEF starts (CefAppProtocol).
let app = OACApplication.shared
let delegate = AppDelegate(selfTest: AppPaths.isSelfTest)
app.delegate = delegate

NativeMessaging.importHosts(into: AppPaths.chromiumData)

// Self-test: does a copy of Arc's profile (extensions, settings) load?
if AppPaths.isSelfTest, arguments.contains("--arc-profile-test") {
    try? ArcProfileImport.cloneProfile(into: AppPaths.chromiumData.appendingPathComponent("Default"))
}

// A full import from Arc replaces the profile before Chromium opens it.
ArcProfileImport.runIfPending(chromiumData: AppPaths.chromiumData) { History().importChromiumHistory(from: $0) }

let settings = OACEngineSettings()
settings.rootCachePath = AppPaths.chromiumData.path
// Ad-hoc signed builds change signature on every build; the real keychain
// would ask for "OpenArch Safe Storage" each time.
settings.useMockKeychain = true
settings.extensionPaths = AppPaths.bundledExtensions("BuiltinExtensions")
if AppPaths.isSelfTest {
    // The probe extension checks extension APIs. The self-test window sits
    // behind other windows, so Chromium must not treat it as hidden, and its
    // (muted) test audio must start without a click.
    if !arguments.contains("--marketing") && !arguments.contains("--show") {
        settings.extensionPaths += AppPaths.bundledExtensions("Extensions")
    }
    // --extension <dir>: more unpacked extensions; --pin-extension <id>: show
    // one in the toolbar (for the popup timing test).
    for (index, argument) in arguments.enumerated() where index + 1 < arguments.count {
        if argument == "--extension" { settings.extensionPaths.append(arguments[index + 1]) }
    }
    let pinned = arguments.enumerated().filter { $0.offset > 0 && arguments[$0.offset - 1] == "--pin-extension" }.map(\.element)
    if !pinned.isEmpty {
        let profile = AppPaths.chromiumData.appendingPathComponent("Default", isDirectory: true)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let preferences: [String: Any] = ["extensions": ["pinned_extensions": pinned]]
        try? JSONSerialization.data(withJSONObject: preferences).write(to: profile.appendingPathComponent("Preferences"))
    }
    settings.extraSwitches = [
        "disable-backgrounding-occluded-windows", "disable-renderer-backgrounding",
        "disable-background-timer-throttling", "autoplay-policy=no-user-gesture-required",
    ]
    if let vmodule = arguments.firstIndex(of: "--chromium-vmodule").map({ arguments[$0 + 1] }) {
        settings.extraSwitches += ["enable-logging=stderr", "vmodule=" + vmodule]
    }
}
if let index = arguments.firstIndex(of: "--remote-debugging-port"), index + 1 < arguments.count {
    settings.remoteDebuggingPort = Int(arguments[index + 1]) ?? 0
} else if !AppPaths.isSelfTest {
    // Settings › KI-Steuerung: the DevTools protocol for AI agents.
    settings.remoteDebuggingPort = AIControl.port
}
guard OACEngine.start(with: settings) else {
    fatalError("Chromium failed to start")
}
OACEngine.runMessageLoop()
OACEngine.shutdown()
