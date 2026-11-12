import pathlib
import unittest

import localize


class LocalizationExtractionTests(unittest.TestCase):
    def test_explicit_ui_strings_bypass_code_and_identifier_filters(self):
        path = pathlib.Path("App/Sources/OpenArch/UI/SettingsView.swift")
        for value in ["nie", "jetzt", "gestern", "einmal", "Gelöscht; der Link zeigt noch den letzten Stand.",
                      "Erstelle meinen Morning Brief für heute, {{DATUM}}, als eigenständige HTML-Seite."]:
            with self.subTest(value=value):
                self.assertTrue(localize.interesting(path, value, False, True))

    def test_conditional_ui_copy_with_semicolons_is_extracted(self):
        text = '''Text(L(live
            ? "Die Lesezeichen liegen verschlüsselt auf dem Teilen-Server; der Schlüssel steht nur im Link."
            : "Die Lesezeichen reisen verschlüsselt im Link selbst; kein Server ist beteiligt."))'''
        path = pathlib.Path("App/Sources/OpenArch/UI/ShareWindow.swift")
        values = list(localize.swift_strings(text))
        self.assertEqual(len(values), 2)
        for start, _, value, _, interpolated in values:
            with self.subTest(value=value):
                self.assertTrue(localize.interesting(path, value, interpolated, localize.is_ui_call(text, start)))

    def test_non_ui_code_and_identifiers_stay_excluded(self):
        path = pathlib.Path("App/Sources/OpenArch/Browser/PageChat.swift")
        for value in ["sidebar.left", "document.body.innerText;", "const text = 'für';", "#ABCDEF", " · "]:
            with self.subTest(value=value):
                self.assertFalse(localize.interesting(path, value, False, False))

    def test_every_extracted_key_has_translations(self):
        translations = localize.read_translations()
        for key in localize.extract():
            with self.subTest(key=key):
                row = translations.get(localize.digest(key))
                self.assertIsNotNone(row)
                for language in ["en", "fr", "es", "it"]:
                    self.assertTrue(row[language])
                    self.assertEqual(localize.placeholders(row[language]), localize.placeholders(key))


if __name__ == "__main__":
    unittest.main()
