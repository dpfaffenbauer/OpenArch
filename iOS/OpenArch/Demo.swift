import SwiftUI
import UIKit

/// The App Store preview's run of the app, in debug builds: launched with
/// -demo, it starts from a library of made-up sites under .example, which
/// are nobody's brand and need no network, and plays through the app's
/// sheets on a fixed timeline. Each scene prints when it starts, for cutting
/// the recording ("[demo] scene <name> <seconds since 1970>").
enum Demo {
    static var isRequested: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-demo")
        #else
        false
        #endif
    }

    static var testsFold: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-testFold")
        #else
        false
        #endif
    }

    @MainActor static func prepared(_ library: Library) -> Library {
        #if DEBUG
        if isRequested { seed(library) }
        #endif
        return library
    }
}

#if DEBUG
extension Demo {
    struct Site {
        let host: String
        let title: String
        let symbol: String
        let color: String
        let headline: String
        let intro: String
        let cards: [(String, String)]
    }

    static let sites = [
        Site(host: "berghuette.example", title: "Berghütte am Grat", symbol: "mountain.2.fill", color: "#2BB3A3",
             headline: "Über den Wolken frühstücken",
             intro: "Zwölf Betten, ein Kachelofen und der schönste Sonnenaufgang im Tal.",
             cards: [("Zimmer", "Vom Lager bis zur Stube"), ("Anreise", "Zwei Stunden ab der Talstation"),
                     ("Küche", "Knödel, Kaspressknödel, Kuchen")]),
        Site(host: "wanderkarte.example", title: "Wanderkarte", symbol: "map.fill", color: "#55B860",
             headline: "Drei Tage, drei Gipfel",
             intro: "Die Route von Hütte zu Hütte, mit Höhenprofil und Einkehr.",
             cards: [("Tag 1", "Vom Tal zum Grat"), ("Tag 2", "Über die Scharte"), ("Tag 3", "Zurück am See entlang")]),
        Site(host: "talbahn.example", title: "Talbahn Fahrplan", symbol: "tram.fill", color: "#3FA9F5",
             headline: "Jede halbe Stunde ins Tal",
             intro: "Abfahrten, Umstiege und die letzte Bahn am Abend.",
             cards: [("Morgens", "Ab der ersten Bahn"), ("Mittags", "Mit Radabteil"), ("Abends", "Letzte Talfahrt")]),
        Site(host: "roestwerk.example", title: "Röstwerk", symbol: "cup.and.saucer.fill", color: "#E5A33B",
             headline: "Kaffee aus der Nachbarschaft",
             intro: "Jede Woche frisch geröstet, im Laden und zum Mitnehmen.",
             cards: [("Espresso", "Kräftig und rund"), ("Filter", "Hell und fruchtig"), ("Laden", "Montag bis Samstag")]),
        Site(host: "nordlicht.example", title: "Projekt Nordlicht", symbol: "sparkles", color: "#5E81F4",
             headline: "Alles für den Start",
             intro: "Der Plan, die offenen Punkte und wer woran arbeitet.",
             cards: [("Plan", "Die nächsten Schritte"), ("Offen", "Sieben Punkte"), ("Team", "Vier Leute, zwei Standorte")]),
        Site(host: "gartenkueche.example", title: "Gartenküche", symbol: "fork.knife", color: "#F0784A",
             headline: "Tomatensuppe mit Basilikum",
             intro: "Dreißig Minuten, ein Topf, und es reicht für alle.",
             cards: [("Zutaten", "Was du brauchst"), ("Zubereitung", "Fünf Schritte"), ("Dazu", "Geröstetes Brot")]),
        Site(host: "ideenbuch.example", title: "Ideenbuch", symbol: "lightbulb.fill", color: "#D85CB4",
             headline: "Was du dir merken wolltest",
             intro: "Skizzen, Links und halbe Gedanken, alle an einem Ort.",
             cards: [("Neu", "Von dieser Woche"), ("Später", "Noch nicht dran"), ("Fertig", "Abgehakt")]),
    ]

    static func site(_ host: String) -> Site {
        sites.first { $0.host == host }!
    }

    @MainActor private static func tab(_ host: String) -> Item {
        .tab(url: "https://\(host)/", title: site(host).title)
    }

    @MainActor private static func seed(_ library: Library) {
        for site in sites {
            Favicons.shared.seed(site.host, icon(site))
        }
        let trip = Space(name: "Reise", icon: "airplane", colorHex: "#2BB3A3")
        trip.pinned = [.folder("Bergtour", children: [tab("wanderkarte.example"), tab("talbahn.example")])]
        let work = Space(name: "Arbeit", icon: "briefcase.fill", colorHex: "#5E81F4")
        work.pinned = [.folder("Nordlicht", children: [tab("nordlicht.example")])]
        work.today = [tab("ideenbuch.example")]
        let kitchen = Space(name: "Küche", icon: "fork.knife", colorHex: "#F0784A")
        kitchen.pinned = [tab("gartenkueche.example")]
        let ideas = Space(name: "Ideen", icon: "lightbulb.fill", colorHex: "#D85CB4")
        ideas.today = [tab("ideenbuch.example")]
        library.spaces = [trip, work, kitchen, ideas]
        library.selectedSpaceID = trip.id
        library.favorites = [tab("roestwerk.example"), tab("gartenkueche.example"), tab("nordlicht.example"),
                             tab("ideenbuch.example")]
    }

    @MainActor private static func icon(_ site: Site) -> UIImage {
        let size = CGSize(width: 96, height: 96)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(hex: site.color)?.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 22).fill()
            let configuration = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
            if let symbol = UIImage(systemName: site.symbol, withConfiguration: configuration)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2))
            }
        }
    }

    static func page(for url: URL) -> String? {
        guard isRequested, let host = url.host(), let site = sites.first(where: { $0.host == host }) else { return nil }
        let cards = site.cards.enumerated().map { index, card in
            "<a class=card><div class=thumb style=\"filter:hue-rotate(\(index * 24)deg)\"></div><h3>\(card.0)</h3><p>\(card.1)</p></a>"
        }.joined()
        return """
            <!doctype html><html lang=de><head><meta charset=utf-8>
            <meta name=viewport content="width=device-width,initial-scale=1"><title>\(site.title)</title><style>
            :root{--c:\(site.color)}*{box-sizing:border-box}body{margin:0;font:17px/1.45 -apple-system,system-ui;color:#1c1c1e;background:#fafaf8}
            nav{display:flex;justify-content:space-between;padding:16px 22px;font-weight:700}nav span:last-child{color:var(--c)}
            .hero{position:relative;height:320px;background:linear-gradient(170deg,var(--c),#fff0 130%),#20242c;overflow:hidden}
            .hero svg{position:absolute;bottom:0;width:100%;height:70%}
            main{padding:26px 22px 60px;max-width:760px;margin:auto}h1{font-size:34px;line-height:1.1;margin:0 0 10px;letter-spacing:-.02em}
            .intro{font-size:19px;color:#55565c;margin:0 0 26px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:14px}
            .card{display:block;background:#fff;border-radius:18px;padding:12px;box-shadow:0 2px 14px #0000000f}
            .thumb{height:120px;border-radius:12px;background:linear-gradient(135deg,var(--c),#ffffff66),#20242c;margin-bottom:12px}
            h3{margin:0 0 2px 4px;font-size:18px}.card p{margin:0 0 6px 4px;color:#6c6d73;font-size:15px}
            </style></head><body><nav><span>\(site.title)</span><span>Menü</span></nav>
            <div class=hero><svg viewBox="0 0 800 300" preserveAspectRatio="none">
            <path fill="#ffffff2e" d="M0 300V170l130-90 110 70 150-120 140 110 120-70 150 110v120z"/>
            <path fill="#ffffff55" d="M0 300v-80l170-70 130 60 170-90 130 80 200-50v150z"/>
            <path fill="#fafaf8" d="M0 300v-40q200-50 400-10t400-20v70z"/></svg></div>
            <main><h1>\(site.headline)</h1><p class=intro>\(site.intro)</p><div class=grid>\(cards)</div></main></body></html>
            """
    }
}

/// A pixel in the display's rounded corner that never stays the same: the
/// simulator's recorder holds back a frame until there is another after it.
struct DemoHeartbeat: View {
    var body: some View {
        TimelineView(.animation) { context in
            Color.white
                .opacity(Int(context.date.timeIntervalSinceReferenceDate * 30) % 2 == 0 ? 0.02 : 0.03)
                .frame(width: 1, height: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Plays the demo on a fixed timeline.
@MainActor
final class DemoDirector {
    private let browser: Browser
    private let beat = 0.46875

    init(browser: Browser) {
        self.browser = browser
    }

    private var regular: Bool {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?
            .traitCollection.horizontalSizeClass == .regular
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func scene(_ name: String) {
        print("[demo] scene \(name) \(Date().timeIntervalSince1970)")
    }

    private func sidebar(_ shown: Bool) {
        if regular {
            withAnimation(.easeOut(duration: 0.25)) { browser.sidebarVisible = shown }
        } else if shown {
            browser.present(.sidebar)
        } else {
            browser.sheet = nil
        }
    }

    private func space(_ name: String) -> Space {
        browser.library.spaces.first { $0.name == name }!
    }

    private func type(_ text: String) async {
        for end in 1...text.count {
            browser.demoQuery = String(text.prefix(end))
            await wait(0.075)
        }
    }

    func run() async {
        print("[demo] start")
        // Shown once before the scenes, so that they are there at once, on the beat.
        sidebar(false)
        for item in browser.library.favorites + browser.space.pinned[0].children {
            browser.select(item)
            await wait(0.8)
        }
        browser.activeItem = nil
        browser.space.activeItemID = nil
        // The recorder catches up here.
        await wait(4)

        // The spaces, one color after the other.
        sidebar(true)
        await wait(1)
        scene("spaces")
        for name in ["Arbeit", "Küche", "Ideen", "Reise"] {
            withAnimation(.easeOut(duration: 0.2)) { browser.switchSpace(to: space(name)) }
            await wait(beat * 2)
        }
        await wait(beat)

        // The address field, and a page.
        if !regular { sidebar(false) }
        await wait(0.8)
        browser.present(.commandBar(.newTab))
        await wait(0.9)
        scene("command")
        await type("berghuette.example")
        await wait(0.5)
        browser.go("berghuette.example", mode: .newTab)
        browser.demoQuery = nil
        // A fresh web view takes its time here, which the cut leaves out.
        await wait(0.5)
        while browser.activeItem?.isLoading == true {
            await wait(0.1)
        }
        await wait(0.3)
        scene("page")
        await wait(beat * 4)

        // Pinned into a folder, where it stays.
        guard let page = browser.activeItem, let folder = browser.space.folders.first else { return }
        sidebar(true)
        await wait(1)
        scene("pin")
        withAnimation(.easeOut(duration: 0.3)) { browser.pin(page, into: folder) }
        await wait(beat * 4)
        withAnimation(.easeOut(duration: 0.2)) { browser.select(folder.children[0]) }
        await wait(beat * 4)
        if regular {
            scene("rail")
            sidebar(false)
            await wait(beat * 4)
            sidebar(true)
            await wait(beat * 3)
        } else {
            await wait(0.6)
        }

        // Everywhere in one tap: favorites and the other spaces.
        scene("tabs")
        for item in browser.library.favorites {
            browser.select(item)
            await wait(beat * 2)
        }
        browser.select(space("Reise").pinned[0].children[0])
        await wait(0.6)
        // Reading on: the page to the edges, the bars out of the way.
        scene("read")
        _ = try? await browser.activeTab?.webView.evaluateJavaScript("window.scrollTo({top: 260, behavior: 'smooth'}); 0")
        await wait(beat * 4)
        _ = try? await browser.activeTab?.webView.evaluateJavaScript("window.scrollTo({top: 0, behavior: 'smooth'}); 0")
        await wait(beat * 2)

        // Shared as an encrypted link, with its code.
        browser.present(.share(.folder(folder)))
        await wait(1)
        scene("share")
        browser.demoCreatesLink = true
        for _ in 0..<150 where !browser.demoLinkIsReady {
            await wait(0.1)
        }
        await wait(0.2)
        scene("qr")
        await wait(beat * 5)
        browser.sheet = nil
        await wait(0.8)

        // Back to the start.
        browser.activeItem = nil
        browser.space.activeItemID = nil
        sidebar(regular)
        withAnimation(.easeOut(duration: 0.3)) { browser.switchSpace(to: space("Reise"), restoring: false) }
        await wait(0.6)
        scene("end")
        // The recorder keeps only frames with something new after them.
        for name in ["Arbeit", "Küche", "Ideen", "Reise", "Arbeit"] {
            await wait(beat * 2)
            withAnimation(.easeOut(duration: 0.2)) { browser.switchSpace(to: space(name), restoring: false) }
        }
        await wait(0.5)
        print("[demo] done")
    }
}
#endif
