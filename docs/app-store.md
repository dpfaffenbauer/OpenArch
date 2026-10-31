# Submitting OpenArch for iPhone and iPad

Bundle ID `at.pfaffenbauer.openarch`, team `5QAM4Z73EV`, version `0.1.0`, German only.

## In the repo

- Texts: `fastlane/metadata/` (name, subtitle, description, keywords, URLs, categories, notes for App Review)
- Privacy manifest: `iOS/OpenArch/PrivacyInfo.xcprivacy`
- Privacy policy: `website/datenschutz/`, published with the site once merged

To send the texts (needs an App Store Connect login or API key; submits nothing):

```bash
fastlane deliver --app_identifier at.pfaffenbauer.openarch --skip_binary_upload true --skip_screenshots true --submit_for_review false
```

## Made locally, not in the repo

`build/` is ignored. Recreate with `scripts/app-preview.py` (a debug build, status bar set to 9:41):

| Slot | Files | Required |
|---|---|---|
| iPhone, 6.9" | `build/app-store/screenshots/iphone/` (1320x2868) | yes |
| iPad, 13" | `build/app-store/screenshots/ipad/` (2064x2752) | yes |
| iPhone Duo, outer | `build/app-store/screenshots/duo-aussen/` (1398x2034) | from April 2027 |
| iPhone Duo, inner | `build/app-store/screenshots/duo-innen/` (2853x2007) | from April 2027 |
| Preview, iPhone | `build/app-preview/OpenArch-Preview-iPhone-886x1920.mp4` | no |
| Preview, iPhone Duo | `build/app-preview/OpenArch-Preview-iPhoneDuo-886x1920.mp4` | no; format unconfirmed |

Poster frame for the previews: the logo at the end, about 23 s.

Apple's page lists the medium iPhone (6.1") as the required slot and says larger screenshots scale down. Should App Store Connect still ask for it, take the same scenes on an iPhone 18 Pro.

## Before submitting

1. `website/datenschutz/index.html`: replace `[ANSCHRIFT UND E-MAIL ERGÄNZEN]`, have the text checked, merge, and open https://openarch.app/datenschutz/.
2. Create the app record in App Store Connect, with primary language German.
3. Archive with Xcode 27.1 or later, and upload.

## Answers in App Store Connect

| Question | Answer |
|---|---|
| Age rating | "Unrestricted Web Access": yes, which gives 16+. Everything else: no |
| App Privacy | Search History, not linked to the user, not for tracking, for App Functionality. Nothing else |
| Content rights | Shows third-party content (websites): yes |
| Encryption | Declared in `Info.plist` (`ITSAppUsesNonExemptEncryption` false: only Apple's own frameworks) |
| Price | Free |
| EU trader status (Digital Services Act) | Yours to declare |
| App Review contact | Yours to fill in |

Why App Privacy reads this way: Apple exempts traffic to the open web, and the relay holds only ciphertext it cannot read. What is typed for suggestions leaves the device for the search engine, so it is declared.
