# Changelog

Notable changes to Laer are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.6] - 2026-11-25

Bug fixes and polish.

- Browser sign-in through `ASWebAuthenticationSession` with PKCE, and an option to remove all local data on sign-out.
- Security and privacy hardening for local storage, downloads and Office previews.
- Fixes for plan timezones, Messages pagination, calendar errors, sign-out races and accessibility.
- Prefetching and on-device lecture briefs are now off by default with a quiet first-run card.
- Added MIT license, `PRIVACY.md` and `SECURITY.md`.

## [0.1.5] - 2026-11-22

### Added
- Course notifications open the relevant page in Laer. Links with a native destination open that item directly.
- Supported itslearning links in course text, Messages and readings open in Laer. Assignments opened from Home go straight to their details.
- Messages show attachments in Laer and load earlier messages as you scroll.

### Changed
- Course files open sooner. The reader shows the first PDF page while the file downloads, and Office previews as they convert.
- Smoother switching in the sidebar.

## [0.1.4] - 2026-11-19

### Added
- Arrange Home: remove, add back, move and resize sections.
- Two-finger swipe and back/forward history in the main window.
- A Settings window, now home to the search options.

### Changed
- Opening a class from the calendar or Home opens its plan.
- Search groups results by kind in tabs, groups pages from the same document, keeps results while you type, and shows announcement authors.
- Messages show sent messages on the right and keep a reply draft per conversation.
- Course text keeps its formatting and can be selected.
- Layout and spacing polish across Home, Calendar, courses, files and messages.

### Fixed
- Window buttons no longer jump when switching screens.

## [0.1.3] - 2026-11-18

### Changed
- Redesigned sidebar and search palette.
- Home shows upcoming classes, deadlines and course updates together.
- Plans can be browsed by topic. Calendar adds Day and School week views.
- One click on the reader divider expands a PDF, and another restores the split view.

## [0.1.2] - 2026-11-17

### Added
- In-app updates with Sparkle: one click downloads, installs and restarts. *Check for Updates…* is in the app menu.
- Institution search as you type, by name or short name.
- A new tab page in the file viewer (⌘T) with search, recent files and shortcuts.
- Slides open as PDF, with the original file and PowerPoint export still available.
- Page rotation in the pages panel.
- Opt-in lecture briefs, made on your Mac with Apple Intelligence.
- A menu bar icon with upcoming lectures.

[Unreleased]: https://github.com/Ckoba/Laer/compare/v0.1.6...HEAD
[0.1.6]: https://github.com/Ckoba/Laer/releases/tag/v0.1.6
[0.1.5]: https://github.com/Ckoba/Laer/releases/tag/v0.1.5
[0.1.4]: https://github.com/Ckoba/Laer/releases/tag/v0.1.4
[0.1.3]: https://github.com/Ckoba/Laer/releases/tag/v0.1.3
[0.1.2]: https://github.com/Ckoba/Laer/releases/tag/v0.1.2
