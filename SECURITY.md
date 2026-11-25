# Security

## Reporting a vulnerability

Please report vulnerabilities privately through [GitHub Security Advisories](https://github.com/Ckoba/Laer/security/advisories/new) ("Report a vulnerability"). Do not open a public issue. Do not include real account data, tokens, cookies or school content; a synthetic reproduction using `example.itslearning.com` values is enough.

You can expect an acknowledgement within a week. Fixes ship in a new release, and the advisory is published once that update is available.

## Supported versions

Only the latest release is supported. Laer updates itself, so fixes are not backported.

## Architecture

| Area | What Laer does |
| --- | --- |
| App Sandbox | `Laer.app` is sandboxed with outgoing network access, read/write access to files you pick, and Sparkle's two installer mach services. It has no other entitlements. |
| Hardened Runtime | Every executable in the bundle is signed with the Hardened Runtime and a secure timestamp. |
| Tokens | OAuth access and refresh tokens are stored in the macOS Keychain, sent only in the `Authorization` header, and never put in URLs or logs. |
| Sign-in | `ASWebAuthenticationSession` opens the institution's own login page in a system browser sheet, so Laer never sees your password. The authorization code flow uses PKCE (`S256`) and a fresh `state` for each attempt. |
| Website-session fallback | Opt-in only. Runs in Laer's own WebKit data store, separate from Safari. Signing out clears that store and the fallback cookies saved to the Keychain. |
| Logging | Operation names, route templates, status codes and error categories only. No URLs with query values, cookies, request or response bodies, or course text. |
| Responses | Status, content type and schema are checked. A login page returned as HTTP 200 is treated as signed out. |
| Writes | Every write (send, submit, delete, mark) is a single explicit action in the UI and is never retried automatically. |

### `LaerQuickLookService`

Office previews need `qlmanage`, which has to run as a separate process and talk to the Quick Look daemon. The App Sandbox forbids both, so this XPC service, embedded in `Laer.app/Contents/XPCServices`, is **not sandboxed**. Its reach is limited in other ways:

- When signed with a team, it accepts connections only from Laer's own code signature.
- It accepts one Office file and one empty output folder, both inside a `LaerOffice-` scratch folder in Laer's temporary directory. Paths are canonicalised; relative, option-like and traversing paths are rejected; and only Office file extensions are accepted.
- `qlmanage -x` renders in the system's own sandboxed Quick Look daemon, so no generator is loaded into the unsandboxed process.
- It contains no network code and does nothing else.

### Updates

[Sparkle 2](https://sparkle-project.org) checks `appcast.xml` from this repository's latest GitHub release over HTTPS. An update is installed only if its EdDSA signature matches the public key built into Laer (`SUPublicEDKey`) **and** its Developer ID code signature matches the installed app. No system profile is sent.

Releases are signed with Developer ID, notarized by Apple, and published with `SHA256SUMS`. Releases built through `.github/workflows/release.yml` also include a GitHub build provenance attestation. See [Verify a release](README.md#verify-a-release).

## Threat model

**In scope:** a network attacker (TLS is never weakened and there are no ATS exceptions), a malicious or compromised download or update, malicious content in course pages or files, other local apps running without your user's privileges, and accidental leaks through logs, crash reports or the repository.

**Out of scope:** malware running as your macOS user (it can read your files, and your Keychain items while the Keychain is unlocked), a compromised itslearning or institution identity provider, and a compromised Apple signing or notarization chain.

## Known caveats

- **Shared OAuth client.** Laer signs in with the public client ID that itslearning's own mobile app and other open-source clients use (`10ae9d30-1853-48ff-81cb-47b58a325685`, scope `"SCOPE"`). It is not registered to Laer. itslearning can revoke or restrict it at any time, and using it may conflict with itslearning's terms. The token endpoint does not authenticate the client, so any app using this ID gets the same access. PKCE protects the code exchange, not the client's identity.
- **Unofficial.** Laer is not affiliated with itslearning. Its routes are worked out from public clients and documentation and may change without notice.
- **Shared browser sign-in session.** `ASWebAuthenticationSession` uses your default browser's session (`prefersEphemeralWebBrowserSession = false`) so saved passwords and passkeys work. Signing out of Laer clears Laer's tokens and caches, but not your browser's session with your institution. On a shared Mac, sign out in your browser too.
- **Fallback session.** When Laer cannot verify a website account, it keeps that session's local data in a new temporary directory (`tmp/LaerEphemeral-*`). These directories are removed on sign-out, on a normal quit and at the next launch.
