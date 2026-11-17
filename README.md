# Laer

A native macOS client for itslearning: courses, updates, materials with offline files, tasks, plans, calendar, messages and notifications, in one quiet, keyboard-friendly app. A Windows preview is in `LaerWindows`.

Laer is unofficial and is not affiliated with itslearning.

## Install

Download the latest `Laer-<version>.dmg` from [Releases](../../releases/latest), open it and drag Laer into Applications. It is signed with a Developer ID and notarized by Apple, and requires macOS 14 or later.

Laer updates itself: when a new version is out, an update button appears in the bottom left of the window. One click downloads, installs and restarts.

On first launch, search for your institution and sign in with its normal login page. Laer never sees your password.

## Build

Requires Xcode 26 or later.

1. Optional, to sign with your own team: copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and fill it in.
2. Build and run the `Laer` scheme in Xcode, or:

```bash
xcodebuild -project Laer.xcodeproj -scheme Laer -destination 'platform=macOS' build
```

## Privacy

Course data, files and sign-in tokens stay on your device. Tokens are kept in the Keychain. There is no telemetry and no server; the only other request Laer makes is the update check against this repository's releases.
