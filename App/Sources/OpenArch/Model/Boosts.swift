import Foundation
import Observation

/// A site's makeover: a color shift, another font, hidden elements and
/// custom CSS and JavaScript, applied to every page of that host.
struct Boost: Codable, Equatable, Identifiable {
    var id = UUID()
    /// "github.com" also covers its subdomains.
    var host: String
    var isEnabled = true
    /// Hue rotation in degrees; 0 leaves the colors alone.
    var hue = 0.0
    var font = ""
    /// CSS selectors of elements zapped away.
    var zapped: [String] = []
    var css = ""
    var javaScript = ""

    func applies(to url: String) -> Bool {
        guard let urlHost = URL(string: url)?.host()?.lowercased() else { return false }
        let host = Boost.normalizedHost(self.host)
        let bare = Boost.normalizedHost(urlHost)
        return !host.isEmpty && (bare == host || bare.hasSuffix("." + host))
    }

    var styleSheet: String {
        var rules: [String] = []
        if hue != 0 {
            rules.append("html { filter: hue-rotate(\(Int(hue))deg) !important; }")
            // Keep photos and videos in their own colors.
            rules.append("img, video, picture, canvas, svg image { filter: hue-rotate(\(-Int(hue))deg) !important; }")
        }
        if !font.isEmpty {
            let family = font.replacingOccurrences(of: "\"", with: "")
            rules.append("body, body *:not(code):not(pre):not(kbd):not(samp):not([class*=\"icon\"]):not([class*=\"Icon\"]) { font-family: \"\(family)\", system-ui, sans-serif !important; }")
        }
        if !zapped.isEmpty {
            rules.append(zapped.joined(separator: ",\n") + " { display: none !important; }")
        }
        if !css.isEmpty {
            rules.append(css)
        }
        return rules.joined(separator: "\n")
    }

    static func normalizedHost(_ host: String) -> String {
        var text = host.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        text = String(text.split(separator: "/").first ?? "")
        return text.hasPrefix("www.") ? String(text.dropFirst(4)) : text
    }
}

/// All boosts, saved in Boosts.json next to the library.
@MainActor @Observable
final class BoostStore {
    static let shared = BoostStore()

    private(set) var boosts: [Boost] = []
    @ObservationIgnored private let file = AppPaths.support.appendingPathComponent("Boosts.json")
    /// Called after every change so open tabs follow at once.
    @ObservationIgnored var onChange: ((Boost) -> Void)?

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Boost].self, from: data) {
            boosts = saved
        }
    }

    func boost(for url: String) -> Boost? {
        boosts.first { $0.applies(to: url) }
    }

    /// The boost for |url|'s site, made on first use.
    func boostForEditing(_ url: String) -> Boost? {
        if let existing = boost(for: url) { return existing }
        guard let host = URL(string: url)?.host(), url.hasPrefix("http") else { return nil }
        let boost = Boost(host: Boost.normalizedHost(host))
        boosts.append(boost)
        return boost
    }

    func update(_ boost: Boost) {
        guard let index = boosts.firstIndex(where: { $0.id == boost.id }) else { return }
        boosts[index] = boost
        save()
        onChange?(boost)
    }

    func delete(_ boost: Boost) {
        boosts.removeAll { $0.id == boost.id }
        save()
        var removed = boost
        removed.isEnabled = false
        onChange?(removed)
    }

    private func save() {
        // Boosts nobody touched are not worth a file entry.
        let worth = boosts.filter { $0.hue != 0 || !$0.font.isEmpty || !$0.zapped.isEmpty || !$0.css.isEmpty || !$0.javaScript.isEmpty }
        if let data = try? JSONEncoder().encode(worth) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// What a page of the boost's site runs: the style sheet (replaced on
    /// every change) and, once per page, the JavaScript.
    static func script(for boost: Boost) -> String {
        let css = boost.isEnabled ? boost.styleSheet : ""
        let js = boost.isEnabled ? boost.javaScript : ""
        let cssLiteral = jsonString(css)
        let jsBlock = js.isEmpty ? "" : """
            if (!window.__openarchBoostRan) {
              window.__openarchBoostRan = true;
              try { \(js)
              } catch (error) { console.error('OpenArch Boost:', error); }
            }
            """
        return """
            (() => {
              const root = document.documentElement;
              if (!root) return;
              let style = document.getElementById('openarch-boost');
              if (!style) {
                style = document.createElement('style');
                style.id = 'openarch-boost';
                (document.head || root).append(style);
              }
              style.textContent = \(cssLiteral);
              \(jsBlock)
            })();
            """
    }

    /// Zap mode: hovering outlines an element, a click hides it and reports
    /// a selector for it; Escape ends the mode.
    static let zapScript = """
        (() => {
          if (window.__openarchZap) return;
          const MARKER = '__openarch_zap__';
          const outline = document.createElement('div');
          outline.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;border:2px solid #ff3b6b;background:rgba(255,59,107,.12);border-radius:4px;transition:all .06s';
          document.documentElement.append(outline);
          const valid = (name) => /^[A-Za-z][\\w-]*$/.test(name) && !/\\d{3,}/.test(name);
          function selectorFor(el) {
            const parts = [];
            while (el && el.nodeType === 1 && el !== document.body && el !== document.documentElement && parts.length < 5) {
              if (el.id && valid(el.id)) { parts.unshift('#' + el.id); break; }
              let part = el.tagName.toLowerCase();
              const classes = [...el.classList].filter(valid).slice(0, 2);
              if (classes.length) part += '.' + classes.join('.');
              const parent = el.parentElement;
              if (parent) {
                const same = [...parent.children].filter((child) => child.tagName === el.tagName);
                if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
              }
              parts.unshift(part);
              el = parent;
            }
            return parts.join(' > ');
          }
          function move(event) {
            const rect = event.target.getBoundingClientRect();
            Object.assign(outline.style, { left: rect.left + 'px', top: rect.top + 'px', width: rect.width + 'px', height: rect.height + 'px' });
          }
          function click(event) {
            event.preventDefault();
            event.stopPropagation();
            const selector = selectorFor(event.target);
            if (selector) {
              event.target.style.setProperty('display', 'none', 'important');
              console.debug(MARKER + ' ' + selector);
            }
          }
          function stop(event) {
            if (event && event.key !== 'Escape') return;
            document.removeEventListener('mousemove', move, true);
            document.removeEventListener('click', click, true);
            document.removeEventListener('keydown', stop, true);
            outline.remove();
            window.__openarchZap = null;
            console.debug(MARKER + '-done');
          }
          document.addEventListener('mousemove', move, true);
          document.addEventListener('click', click, true);
          document.addEventListener('keydown', stop, true);
          window.__openarchZap = stop;
        })();
        """

    static let stopZapScript = "window.__openarchZap && window.__openarchZap();"

    private static func jsonString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}
