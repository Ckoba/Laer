# Contributing

Thanks for your interest in Laer. It is a native macOS client for itslearning, written in Swift 6 and SwiftUI. Please read this page before opening a pull request.

## Build

You need macOS 14 or later and **Xcode 26** or later.

1. Optional: to sign with your own team, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and fill it in. Git ignores this file. Never commit a team ID.
2. Open `Laer.xcodeproj` and run the `Laer` scheme, or build from the command line:

```bash
xcodebuild -project Laer.xcodeproj -scheme Laer -destination 'platform=macOS' build
```

## Test

Headless tests (no UI automation):

```bash
xcodebuild -project Laer.xcodeproj -scheme Laer -configuration Debug \
  -destination 'platform=macOS' -skip-testing:LaerMacUITests \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test

swift test --package-path Packages/LaerCore
```

`LaerMacUITests` drives the real screen, so only run it when you can leave the Mac alone.

CI builds with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`, so pull requests must build without warnings.

## Layout

- `LaerMac`: the app (SwiftUI screens, a single `@MainActor @Observable` `AppModel`, and platform adapters).
- `Packages/LaerCore`: models, API, storage and sync. Uses headless Apple frameworks only.
- `LaerQuickLookService`: the Office preview helper (see [SECURITY.md](SECURITY.md)).
- `LaerMacTests`, `LaerMacUITests`: app specs that run against fixtures, and UI smoke checks.

Sparkle is the only third-party runtime dependency. If you want to add another, open an issue to discuss it first.

## Privacy rules

These are hard requirements. Pull requests that break them will be closed.

- Fixtures are written by hand with synthetic values and the host `example.itslearning.com`. Never commit real API responses, names, emails, IDs, course titles, announcements, files, tokens, cookies or signed URLs.
- Never commit probe output or logs from a real account. Logs record operation names, route templates, status codes and error categories only.
- No institution names, hosts, personal paths, machine names or signing team IDs. The institution is chosen at runtime.
- No telemetry, analytics or uploads. Course data stays on the device.
- Do not automate passwords or MFA, read browser cookies, or weaken TLS.
- Test writes (send, submit, delete, mark) with fixtures. Every write must be a single explicit user action.

## Pull requests

- Keep each pull request to one focused change, with a short imperative title.
- Describe what changed and how you tested it. Screenshots of UI changes must use fixture data.
- Add or update tests when behaviour changes.
- Dates follow the user's locale. Do not assume a language, locale or time zone.
- By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).

Please report security issues privately, as described in [SECURITY.md](SECURITY.md).
