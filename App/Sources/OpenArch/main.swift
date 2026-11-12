import AppKit
import OpenArchCore
import OpenArchLocalization

setvbuf(stdout, nil, _IOLBF, 0)

// Before AppKit or SwiftUI reads a localized string: apply the saved
// language choice to the bundle. A change in Settings takes effect on the
// next launch, which Settings explains.
Localization.bootstrap()

let arguments = CommandLine.arguments
AppPaths.isSelfTest = arguments.contains("--selftest")

// scripts/make-icons.sh: the app icon and the website's, from AppIcons.
if let index = arguments.firstIndex(of: "--export-icons"), index + 1 < arguments.count {
    AppIcons.exportIcons(to: URL(fileURLWithPath: arguments[index + 1]))
    exit(0)
}

// --selftest --keychain-test: three launches on one data folder, from the
// mock keychain to the login keychain (SelfTestKeychain.swift).
if AppPaths.isSelfTest, arguments.contains("--keychain-test") {
    exit(KeychainSelfTest.runPhases())
}

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

// The key for passwords and cookies: "OpenArch Safe Storage" in the login
// keychain for Developer ID builds, the mock keychain for ad-hoc builds
// (--login-keychain / --mock-keychain choose). Data still on the mock key
// moves to the keychain's here, before Chromium opens it.
var safeStorageArguments = arguments
switch KeychainSelfTest.phase {
case 1: safeStorageArguments.append("--mock-keychain")
case 2, 3: safeStorageArguments.append("--login-keychain")
default: break
}
SafeStorage.prepare(chromiumData: AppPaths.chromiumData, arguments: safeStorageArguments)

// A full import from Arc replaces the profile before Chromium opens it.
ArcProfileImport.runIfPending(chromiumData: AppPaths.chromiumData) { History().importChromiumHistory(from: $0) }
// Logins and passwords from other browsers or a CSV file, the same way.
if !AppPaths.isSelfTest {
    CredentialImport.runIfPending(chromiumData: AppPaths.chromiumData)
}

// An imported backup (Settings › Info › Sicherung) replaces the library
// before anything reads it.
if !AppPaths.isSelfTest {
    Backups.restorePendingIfAny()
}

let settings = OACEngineSettings()
settings.rootCachePath = AppPaths.chromiumData.path
settings.useMockKeychain = !SafeStorage.usesLoginKeychain
settings.keychainServiceName = SafeStorage.service
settings.keychainAccountName = SafeStorage.account
settings.extensionPaths = AppPaths.bundledExtensions("BuiltinExtensions")
ProtectedContent.prepare(extensions: settings.extensionPaths)
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
    // As after a session in a space on another profile: Chrome would then
    // start its global context ("Default") on that profile (see OACEngine).
    let localState = AppPaths.chromiumData.appendingPathComponent("Local State")
    if !FileManager.default.fileExists(atPath: localState.path) {
        let state: [String: Any] = ["profile": ["last_used": "Profile 2"]]
        try? JSONSerialization.data(withJSONObject: state).write(to: localState)
    }
    settings.extraSwitches = [
        "disable-backgrounding-occluded-windows", "disable-renderer-backgrounding",
        "disable-background-timer-throttling", "autoplay-policy=no-user-gesture-required",
    ]
    // The call test: Chromium's fake camera and microphone, without asking
    // (nor macOS).
    if arguments.contains("--call-test") {
        settings.extraSwitches += ["use-fake-device-for-media-stream", "use-fake-ui-for-media-stream"]
    }
    if let vmodule = arguments.firstIndex(of: "--chromium-vmodule").map({ arguments[$0 + 1] }) {
        settings.extraSwitches += ["enable-logging=stderr", "vmodule=" + vmodule]
    }
}
// OpenArch decides what a first launch shows (the onboarding); Chrome's own
// first-run pages and its default browser question never appear.
settings.extraSwitches += ["no-first-run", "no-default-browser-check"]
if let index = arguments.firstIndex(of: "--remote-debugging-port"), index + 1 < arguments.count {
    settings.remoteDebuggingPort = Int(arguments[index + 1]) ?? 0
} else if !AppPaths.isSelfTest {
    // Settings › KI-Steuerung: the DevTools protocol for AI agents.
    settings.remoteDebuggingPort = AIControl.port
}
guard OACEngine.start(with: settings) else {
    // Usually another OpenArch (say, a second copy of the app) already uses
    // this profile folder; Chromium has handed it this launch. Bring it to
    // the front and leave quietly.
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if let running = others.first {
        if !AppPaths.isSelfTest { running.activate() }
        print("[OpenArch] already running as \(running.processIdentifier), handed the launch over")
        exit(0)
    }
    let alert = NSAlert()
    alert.messageText = "OpenArch konnte Chromium nicht starten."
    alert.informativeText = "Starte OpenArch bitte noch einmal. Wenn es wieder passiert, hilft ein Neustart des Macs."
    alert.runModal()
    exit(1)
}
OACEngine.runMessageLoop()
OACEngine.shutdown()
