# Privacy

Laer has no server, no account of its own, no analytics, no telemetry and no crash reporting. Course data stays on your Mac. This page lists every destination Laer contacts and everything it stores.

## Network destinations

| Destination | When | What is sent |
| --- | --- | --- |
| `www.itslearning.com` | Choosing an institution | Your search text, sent to itslearning's public, unauthenticated site lookup. |
| Your institution's `*.itslearning.com` site | Sign-in, token refresh and every screen | The OAuth authorization and token requests, then API requests with your access token in the `Authorization` header. In website-session mode, the site's own cookies are sent instead. |
| Your institution's identity provider | Sign-in | Whatever its login page asks for. Browser sign-in opens a system browser sheet (`ASWebAuthenticationSession`). The opt-in website session opens the page inside Laer. |
| `resource.itslearning.com` and the download hosts it redirects to | Opening or saving a file | The request itslearning signs for that file. Redirects stay on HTTPS. |
| External HTTPS image hosts | Showing a profile picture hosted outside itslearning | A plain `GET` with no cookies, tokens or other credentials. These pictures are kept in memory only. |
| An exam-plan address you enter | Only if you add one on Home | A request for that URL, to show the PDF. |
| `github.com/Ckoba/Laer` releases (and GitHub's release-asset download hosts) | At launch, every six hours, and when you choose *Check for Updates…* | A request for `appcast.xml`. If you install an update, also the disk image (GitHub redirects release downloads to its asset CDN, such as `objects.githubusercontent.com` or `release-assets.githubusercontent.com`). Sparkle's system profile is turned off. |
| Links you open | When you open them | Opened in your default browser or the in-app viewer, at your request. |

macOS may contact Apple's services on its own, for example to check Laer's notarization ticket. Laer does not call them directly.

On-device features (lecture briefs, text recognition in search) use Apple's local frameworks and make no network requests.

## Stored on your Mac

Everything below lives in Laer's sandbox container (`~/Library/Containers/app.laer.Laer`) unless noted otherwise.

| Data | Where | Notes |
| --- | --- | --- |
| OAuth access and refresh tokens | Keychain | One item per institution. Never written to files or logs. |
| Website session | In-memory WebKit data, separate from Safari. The website fallback also saves institution cookies to the Keychain. | Used for file access after OAuth sign-in, or for the opt-in website session. |
| Course data snapshots | JSON files under Application Support, per account | Courses, updates, plans, tasks, messages and resources, so Laer works offline. A failed refresh never replaces them. |
| Search index | `search.sqlite` (SQLite FTS5), per account | Titles and text of cached items and of saved PDF and text files. Text recognized from scanned PDFs and images with Apple Vision is added only if you turn on text recognition in Settings. |
| Saved files | `Downloads` under Application Support, per account | Removed only when you ask. |
| Files fetched before you open them | `Downloads` under Application Support, per account | Off by default. Only used if you turn on *Get files before you open them*. Laer evicts these files once they pass 300 MiB. Opening or saving a file keeps it for offline use. |
| Lecture briefs | Under Application Support, per account | Only if you agree when asked. Made on your Mac with Apple Intelligence from readings you saved. |
| Exam-plan PDF | Under Application Support (or the temporary directory, for unverified website sessions) | Only if you add an exam-plan address. |
| Derived viewer caches | Caches (`Caches/`) and `URLCache` | Office files converted to PDF, named temporary copies used to open or export files (`NamedFiles`), and cached HTTP responses for the exam-plan URL. |
| Preferences and UI metadata | `UserDefaults` | Chosen institution, the signed-in `Person`'s cached display name and profile image URL, recent file titles (`recentFiles-<id>`), study links, exam-plan address, appearance, layout and feature switches. |
| Unverified website session data | Container `tmp/LaerEphemeral-*` | Temporary snapshots, downloads, search index, briefs and exam plan, used when an opt-in website session cannot verify your identity. Removed on sign-out, on quit and at the next launch. |
| Exported files | Wherever you choose | Outside Laer's control once written. |

## Removing data

- **Sign Out (Keep Offline Files)** deletes saved credentials, the website session and derived viewer caches. Verified accounts keep their offline files. For an unverified website session, this option is labelled **Sign Out (Deletes Temporary Session Data)** and deletes the temporary session folder right away.
- **Sign Out and Remove All Local Data** (in Settings and the app menu) also deletes snapshots, `search.sqlite`, saved and prefetched files, lecture briefs, the exam-plan PDF, the recent-file titles and exam-plan URL in `UserDefaults`, `URLCache`, and any temporary `LaerEphemeral-*` or `LaerOffice-*` folders, for every account on this Mac.
- **Browser sign-in session.** Browser sign-in (`ASWebAuthenticationSession`) uses your default browser's cookie session so saved passwords and passkeys work. Signing out of Laer does not sign you out of your institution's identity provider in that browser. On a shared Mac, sign out in your browser as well.
- Deleting `~/Library/Containers/app.laer.Laer` after quitting Laer removes everything except the Keychain items. You can remove those in Keychain Access by searching for `app.laer.Laer`.

## Your institution

As with any client, including the website, your institution and itslearning can see how you use their service. Their privacy policies apply to that data.
