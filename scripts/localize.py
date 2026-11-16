#!/usr/bin/env python3
"""Extract OpenArch's UI strings and build the .lproj tables.

Source strings are the German UI text, so the existing SwiftUI literals keep
working as localization keys. `App/Localization/translations.tsv` holds the
translations for the Mac and the iPhone app alike (a German text has one
translation).

Mac: this script extracts the keys from the sources and writes
App/Resources/<code>.lproj/Localizable.strings and InfoPlist.strings.
iPhone and iPad: Xcode keeps the keys in iOS/OpenArch/Localizable.xcstrings
(it adds new ones when it builds); this script fills in the languages there
and in InfoPlist.xcstrings. English already in the catalog stays as it is.

Usage:
  scripts/localize.py --list           # all keys, with hashes
  scripts/localize.py --missing        # keys without translations
  scripts/localize.py --write          # write the .strings files and catalogs
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCALIZATION = ROOT / "App" / "Localization"
TRANSLATIONS = LOCALIZATION / "translations.tsv"
LANGS = ["en", "de", "fr", "es", "it"]

UI_FILE_HINTS = ("/UI/", "/Onboarding/")
GERMAN = re.compile(
    r"ä|ö|ü|ß|Ä|Ö|Ü|"
    r"\b(?:nicht|für|über|während|bitte|danke|jetzt|später|fertig|abbrechen|"
    r"erlauben|entfernen|hinzufügen|löschen|bearbeiten|anzeigen|auswählen|öffnen|"
    r"schließen|speichern|suchen|teilen|kopieren|einfügen|zurück|weiter|vorwärts|"
    r"rückwärts|nächste|vorherige|aktuell|inaktiv|keine|kein|nichts|etwas|schon|"
    r"immer|wieder|damit|dass|welche|welcher|welches|warum|wählen|klicken|tippen|"
    r"beenden|laden|groß|klein|schnell|langsam|weniger|andere|anderes|selbe|"
    r"gleiche|erste|letzte)\b",
    re.IGNORECASE,
)
SKIP = re.compile(
    r"""^(?:
      [a-z0-9][a-z0-9._-]*            # system image names and identifiers
      |(?:https?|www|javascript|x-apple|data|file):?
      |/|~|\.|\#|%(?:@|lld|ld|d|s)
      |\#[0-9A-Fa-f]{6}               # colors
      |[^A-Za-zÄÖÜäöüß]*              # no letters: separators, numbers
      |[a-z]+(?:[A-Z][a-z0-9]*)+$     # camelCase identifiers
      |[A-Z]{2,}[a-z]+(?:[A-Z][a-z]*)+  # prefixed identifiers (CFBundleName)
    )$""",
    re.VERBOSE,
)


def swift_strings(text: str):
    """Yield (start, end, value, line, interpolated) for Swift string literals."""
    i, n = 0, len(text)
    line = 1
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                break
            line += text.count("\n", i, j)
            i = j + 2
            continue
        # raw strings are not used in the UI; plain strings and multiline.
        if text.startswith('"""', i):
            start_line = line
            j = text.find('"""', i + 3)
            if j < 0:
                break
            body = text[i + 3:j]
            line += text.count("\n", i, j)
            # Swift strips the closing delimiter's indentation and the first
            # newline, and does not keep the final newline.
            if body.startswith("\n"):
                body = body[1:]
            lines = body.split("\n")
            closing_indent = ""
            if lines:
                last = lines[-1]
                closing_indent = last[: len(last) - len(last.lstrip())]
                if last.strip() == "":
                    lines = lines[:-1]
            body = "\n".join(l[len(closing_indent):] if l.startswith(closing_indent) else l for l in lines)
            interpolated = "\\(" in body
            # Escapes as Swift reads them, after the indentation: a backslash
            # at the end of a line joins it with the next one.
            body = re.sub(r"\\\n", "", body)
            body = re.sub(r'\\([nt0"\\\'])',
                          lambda m: {"n": "\n", "t": "\t", "0": "\0"}.get(m.group(1), m.group(1)), body)
            yield i, j + 3, body, start_line, interpolated
            i = j + 3
            continue
        if c == '"':
            start = i
            i += 1
            out = []
            interpolated = False
            while i < n:
                ch = text[i]
                if ch == "\\" and i + 1 < n:
                    nxt = text[i + 1]
                    if nxt == "(":
                        # Skip the whole interpolation, including string
                        # literals inside it ("\\(a ? "x" : b)").
                        interpolated = True
                        out.append("\\(")
                        i, depth = i + 2, 1
                        while i < n and depth:
                            ch = text[i]
                            if ch == '"':
                                i += 1
                                while i < n and text[i] != '"':
                                    i += 2 if text[i] == "\\" else 1
                            elif ch == "(":
                                depth += 1
                            elif ch == ")":
                                depth -= 1
                            elif ch == "\n":
                                line += 1
                            i += 1
                        out.append(")")
                        continue
                    escapes = {"n": "\n", "t": "\t", "r": "\r", "0": "\0",
                               '"': '"', "\\": "\\", "'": "'"}
                    if nxt in escapes:
                        out.append(escapes[nxt])
                        i += 2
                        continue
                    if nxt == "u" and i + 2 < n and text[i + 2] == "{":
                        k = text.find("}", i + 3)
                        if k > 0:
                            try:
                                out.append(chr(int(text[i + 3:k], 16)))
                            except ValueError:
                                pass
                            i = k + 1
                            continue
                    out.append(nxt)
                    i += 2
                    continue
                if ch == '"':
                    break
                if ch == "\n":
                    line += 1
                out.append(ch)
                i += 1
            yield start, i + 1, "".join(out), text.count("\n", 0, start) + 1, interpolated
            i += 1
            continue
        i += 1


def context_before(text: str, start: int, length: int = 60) -> str:
    return text[max(0, start - length):start]


def is_ui_call(text: str, start: int) -> bool:
    before = context_before(text, start, 80).rstrip()
    if re.search(r"\bL\s*\(\s*$|\bLocalization\.(?:format|count)\s*\(\s*$", before):
        return True
    # SwiftUI views and the local helpers that build menus or buttons
    # (item and submenu are MainMenu's own constructors).
    if re.search(r"(?:\bText|\bButton|\bLabel|\bSection|\bPicker|\bToggle|\bTextField|\bSecureField|\bLink|\bMenu|\bitem|\bsubmenu)\s*\(\s*$", before):
        return True
    if re.search(r"\.(?:help|navigationTitle|alert|confirmationDialog|accessibilityLabel)\s*\(\s*$", before):
        return True
    if re.search(r"(?:\bLabeledContent|\bNavigationLink|\bContentUnavailableView)\s*\(\s*$|\bString\(\s*localized:\s*$|\blocalizedString\(\s*forKey:\s*$", before):
        return True
    # NSMenuItem(title: "…", NSMenu(title: "…", alert.messageText = "…",
    if re.search(r"(?:NSMenuItem|NSMenu)\(\s*title:\s*$|(?:messageText|informativeText|placeholderString|toolTip)\s*=\s*$", before):
        return True
    # Call-site parameters whose strings are shown (help tooltips, counts,
    # onboarding tuples, and other labelled fields). Each alternative is
    # word-anchored, so e.g. "alreadyDone" never reads as "one".
    if re.search(r"(?:\btitle|\bdetail|\bfooter|\blabel|\bdefaultTitle|\bmessageText|\binformativeText|\bhelp|\btext|\bnote|\bmessage|\bplaceholder|\baccessibilityLabel|\bskipTitle|\bone|\bother)\s*:\s*$", before):
        return True
    # Tuple titles such as primary: ("Weiter", ...).
    if re.search(r"(?:\bprimary|\bsecondary)\s*:\s*\(\s*$", before):
        return True
    return False


def interesting(path: pathlib.Path, value: str, interpolated: bool, ui: bool) -> bool:
    if not value.strip() or len(value) < 2 or interpolated or not any(c.isalpha() for c in value):
        return False
    # Explicit UI calls can contain lowercase labels, semicolons or templates.
    if ui:
        return True
    if SKIP.match(value):
        return False
    # Source code, scripts and injected CSS are never localization keys.
    if re.search(r"[{}]|=>|\b(?:const|document|function|return|window)\b", value):
        return False
    if path.name.startswith("SelfTest"):
        return False
    if GERMAN.search(value):
        return True
    # UI files contain short labels without umlauts ("Port", "Info"); include
    # them unless they look like code.
    if any(h in str(path) for h in UI_FILE_HINTS):
        if re.search(r"[A-ZÄÖÜ ]", value) and not re.search(r"[{};$`]", value):
            return True
    return False


# The shared package's messages (ShareCrypto) are looked up in the app's
# main bundle, so the Mac's tables carry them too.
SOURCES = (ROOT / "App" / "Sources" / "OpenArch", ROOT / "Shared" / "Sources")
RESOURCES = ROOT / "App" / "Resources"
IOS = ROOT / "iOS" / "OpenArch"
TRANSLATED = ["en", "fr", "es", "it"]


def swift_files():
    for folder in SOURCES:
        for path in sorted(folder.rglob("*.swift")):
            if not path.name.startswith("SelfTest"):
                yield path


def interpolated_ui(text: str, start: int, value: str, interpolated: bool) -> bool:
    """A shown literal with \\(…) and words: SwiftUI or String(localized:)
    would look for a key this script cannot know, so it needs L("… %@ …")."""
    if not interpolated or not is_ui_call(text, start):
        return False
    words = re.sub(r"\\\([^)]*\)", "", value)
    return bool(re.search(r"[A-Za-zÄÖÜäöüß]{2,}", words))


def extract(problems: list[str] | None = None):
    keys: dict[str, str] = {}
    for path in swift_files():
        text = path.read_text()
        for start, end, value, line, interpolated in swift_strings(text):
            where = f"{path.relative_to(ROOT)}:{line}"
            if interesting(path, value, interpolated, is_ui_call(text, start)):
                keys.setdefault(value, where)
            elif problems is not None and interpolated_ui(text, start, value, interpolated):
                problems.append(f"{where}: interpolated text, use L(\"… %@ …\", …): {value!r}")
    return keys


def read_catalog(name: str):
    return json.loads((IOS / name).read_text())


def write_catalog(name: str, catalog) -> None:
    # The layout the catalogs have: two-space indent, no final newline.
    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", ": "))
    (IOS / name).write_text(text)


def catalog_keys(catalog):
    """The catalog's keys that are translated (not the shouldTranslate=false ones)."""
    return [key for key, entry in catalog["strings"].items() if entry.get("shouldTranslate") is not False]


def fill_catalog(catalog, values) -> None:
    """Sets the languages from |values| (key -> {lang: value}); keeps what the
    catalog already says for English."""
    for key in catalog_keys(catalog):
        localizations = catalog["strings"][key].setdefault("localizations", {})
        for lang in TRANSLATED:
            if lang == "en" and "en" in localizations:
                continue
            localizations[lang] = {"stringUnit": {"state": "translated", "value": values[key][lang]}}
        # Languages in alphabetical order, as Xcode writes them.
        catalog["strings"][key]["localizations"] = dict(sorted(localizations.items()))


def digest(key: str) -> str:
    return hashlib.sha1(key.encode()).hexdigest()[:10]


def read_translations():
    table = {}
    if not TRANSLATIONS.exists():
        return table
    for line in TRANSLATIONS.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        table[parts[0]] = {lang: value.replace("\\n", "\n").replace("\\t", "\t")
                            for lang, value in zip(["en", "fr", "es", "it"], parts[1:5])}
    return table


def strings_escape(value: str) -> str:
    return (value.replace("\\", "\\\\").replace('"', '\\"')
            .replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r"))


# German is the source language, so its table maps every key to itself. A
# key that differs from its German text only exists to tell two meanings of
# one German word apart ("Links": the settings tab, or the left side).
GERMAN_VALUES = {
    "Links (Webseiten)": "Links",
}


PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|d|s|f|\.\d+f|%)")


def placeholders(value: str):
    return PLACEHOLDER.findall(value)


INFO_PLIST = {
    "NSCameraUsageDescription": {
        "en": "Websites can ask to use your camera.",
        "de": "Websites können nach der Verwendung deiner Kamera fragen.",
        "fr": "Les sites web peuvent demander à utiliser votre caméra.",
        "es": "Los sitios web pueden solicitar el uso de tu cámara.",
        "it": "I siti web possono chiedere di usare la fotocamera.",
    },
    "NSMicrophoneUsageDescription": {
        "en": "Websites can ask to use your microphone.",
        "de": "Websites können nach der Verwendung deines Mikrofons fragen.",
        "fr": "Les sites web peuvent demander à utiliser votre microphone.",
        "es": "Los sitios web pueden solicitar el uso de tu micrófono.",
        "it": "I siti web possono chiedere di usare il microfono.",
    },
    "NSBluetoothAlwaysUsageDescription": {
        "en": "Websites can ask to use your Bluetooth devices.",
        "de": "Websites können nach der Verwendung deiner Bluetooth-Geräte fragen.",
        "fr": "Les sites web peuvent demander à utiliser vos appareils Bluetooth.",
        "es": "Los sitios web pueden solicitar el uso de tus dispositivos Bluetooth.",
        "it": "I siti web possono chiedere di usare i dispositivi Bluetooth.",
    },
    "NSLocationUsageDescription": {
        "en": "Websites can ask for your location.",
        "de": "Websites können nach deinem Standort fragen.",
        "fr": "Les sites web peuvent demander votre position.",
        "es": "Los sitios web pueden solicitar tu ubicación.",
        "it": "I siti web possono chiedere la tua posizione.",
    },
    "NSAppleEventsUsageDescription": {
        "en": "The player in the sidebar can pause Spotify and skip its songs.",
        "de": "Der Player in der Sidebar kann Spotify pausieren und Titel überspringen.",
        "fr": "Le lecteur de la barre latérale peut mettre Spotify en pause et passer des titres.",
        "es": "El reproductor de la barra lateral puede pausar Spotify y cambiar de canción.",
        "it": "Il lettore nella barra laterale può mettere in pausa Spotify e cambiare brano.",
    },
    "NSCalendarsFullAccessUsageDescription": {
        "en": "OpenArch shows your next meeting in the sidebar, with a button to join the call.",
        "de": "OpenArch zeigt dein nächstes Meeting in der Sidebar, mit einem Knopf zum Beitreten.",
        "fr": "OpenArch affiche votre prochaine réunion dans la barre latérale, avec un bouton pour rejoindre l’appel.",
        "es": "OpenArch muestra tu próxima reunión en la barra lateral, con un botón para unirte a la llamada.",
        "it": "OpenArch mostra la prossima riunione nella barra laterale, con un pulsante per partecipare.",
    },
    "NSCalendarsUsageDescription": {
        "en": "OpenArch shows your next meeting in the sidebar, with a button to join the call.",
        "de": "OpenArch zeigt dein nächstes Meeting in der Sidebar, mit einem Knopf zum Beitreten.",
        "fr": "OpenArch affiche votre prochaine réunion dans la barre latérale, avec un bouton pour rejoindre l’appel.",
        "es": "OpenArch muestra tu próxima reunión en la barra lateral, con un botón para unirte a la llamada.",
        "it": "OpenArch mostra la prossima riunione nella barra laterale, con un pulsante per partecipare.",
    },
}


INFO_PLIST_IOS = {
    "NSCameraUsageDescription": {
        "en": "To scan share codes from other devices.",
        "fr": "Pour scanner les codes de partage d’autres appareils.",
        "es": "Para escanear códigos para compartir de otros dispositivos.",
        "it": "Per scansionare i codici di condivisione di altri dispositivi.",
    },
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--missing", action="store_true")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    problems: list[str] = []
    mac_keys = extract(problems)
    catalog = read_catalog("Localizable.xcstrings")
    keys = dict(mac_keys)
    for key in catalog_keys(catalog):
        keys.setdefault(key, "iOS/OpenArch/Localizable.xcstrings")
    translations = read_translations()
    if args.list:
        for key in sorted(keys, key=lambda k: (keys[k], k)):
            print(f"{digest(key)}\t{keys[key]}\t{key}")
        print(f"-- {len(keys)} keys", file=sys.stderr)
        return
    missing = []
    for key in keys:
        row = translations.get(digest(key))
        if not row or any(not row.get(lang) for lang in ["en", "fr", "es", "it"]):
            missing.append(key)
    if args.missing:
        for key in sorted(missing):
            print(f"{digest(key)}\t{keys[key]}\t{key}")
        for problem in problems:
            print(problem)
        print(f"-- {len(missing)} missing of {len(keys)}, {len(problems)} problems", file=sys.stderr)
        return
    if not args.write:
        parser.error("choose --list, --missing or --write")
    for key in keys:
        row = translations.get(digest(key))
        if not row:
            problems.append(f"missing translation: {key!r}")
            continue
        want = placeholders(key)
        for lang in TRANSLATED:
            if not row.get(lang):
                problems.append(f"missing {lang}: {key!r}")
            elif placeholders(row[lang]) != want:
                problems.append(f"placeholder mismatch in {lang}: {key!r} -> {row[lang]!r}")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        sys.exit(1)

    for lang in LANGS:
        folder = RESOURCES / f"{lang}.lproj"
        folder.mkdir(parents=True, exist_ok=True)
        lines = ["/* Generated by scripts/localize.py. Do not edit by hand. */", ""]
        for key in sorted(mac_keys):
            value = GERMAN_VALUES.get(key, key) if lang == "de" else translations[digest(key)][lang]
            lines.append(f'"{strings_escape(key)}" = "{strings_escape(value)}";')
        (folder / "Localizable.strings").write_text("\n".join(lines) + "\n")
        info_lines = ["/* Generated by scripts/localize.py. Do not edit by hand. */", ""]
        for key, table in INFO_PLIST.items():
            info_lines.append(f'"{strings_escape(key)}" = "{strings_escape(table[lang])}";')
        (folder / "InfoPlist.strings").write_text("\n".join(info_lines) + "\n")
    print(f"Wrote {len(mac_keys)} keys to App/Resources ({', '.join(LANGS)})")

    fill_catalog(catalog, {key: translations[digest(key)] for key in catalog_keys(catalog)})
    write_catalog("Localizable.xcstrings", catalog)
    info = read_catalog("InfoPlist.xcstrings")
    fill_catalog(info, INFO_PLIST_IOS)
    write_catalog("InfoPlist.xcstrings", info)
    print(f"Filled {len(catalog_keys(catalog))} keys in iOS/OpenArch/Localizable.xcstrings ({', '.join(TRANSLATED)})")


if __name__ == "__main__":
    main()
