import AppKit
import OpenArchCore

setvbuf(stdout, nil, _IOLBF, 0)

guard OACEngine.loadFramework() else {
    fatalError("Chromium Embedded Framework could not be loaded")
}

let isSelfTest = CommandLine.arguments.contains("--selftest")
let app = OACApplication.shared
let appDelegate = AppDelegate(selfTest: isSelfTest)
app.delegate = appDelegate

let settings = OACEngineSettings()
settings.rootCachePath = AppPaths.dataDirectory(selfTest: isSelfTest).path
settings.extensionPaths = AppPaths.bundledExtensions().map(\.path)
settings.remoteDebuggingPort = 9222
guard OACEngine.start(with: settings) else {
    fatalError("Chromium failed to initialize")
}
log("Chromium \(OACEngine.versionString) started, extensions: \(settings.extensionPaths)")

OACEngine.runMessageLoop()
OACEngine.shutdown()
log("shut down cleanly")
