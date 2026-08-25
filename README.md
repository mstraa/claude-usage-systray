# claude-usage-systray

A native macOS menu bar app that shows how much of your Claude rate limits you have used.

The menu bar shows the rolling 5-hour window and the time it resets. Clicking opens a dropdown
with the 5-hour window, the weekly window across all models, and weekly usage broken down per
model.

```
✳ 27% · 19h
```

Times use a 24-hour clock: `19h` on the hour, `19h23` otherwise.

## What it does

- **At a glance:** percentage of the rolling 5-hour session limit, plus when it resets.
- **Colour coding:** the icon and label turn orange at 75% and red at 90%, driven by whichever
  window is worst — including per-model weekly limits.
- **Dropdown detail:** the 5-hour window, the weekly all-models window, and a row per model, each
  with a progress bar, a reset time and a countdown.
- **Stale-data honesty:** if a refresh fails, the last known numbers stay on screen but are dimmed.
  Once the 5-hour window has provably rolled over with no successful refresh, the label falls back
  to `—` rather than showing a number that is now wrong.
- **Launch at login**, via `SMAppService`.
- **Survives restarts:** the last figures are cached to disk, so a relaunch shows the previous
  numbers immediately instead of a blank menu bar while the first fetch is in flight — or
  failing. The cache holds percentages and timestamps only, never a credential.
- No Dock icon and no window.
- **Gentle on the API:** polls every 15 minutes in the background, and refetches when you open
  the dropdown only if the figures are more than 2 minutes old — so freshness costs a request
  when you are actually looking, not around the clock. On `429` it backs off exponentially up to
  30 minutes and honours `Retry-After`. The usage endpoint rate-limits aggressively and Claude
  Code polls it on the same account, so this app is deliberately unhurried.

## Requirements

- macOS 13 or later
- Xcode **Command Line Tools** (full Xcode is not required)
- Claude Code, signed in — this app reads the token Claude Code already stores

## Build

```bash
git clone git@github.com:mstraa/claude-usage-systray.git
cd claude-usage-systray
./build.sh
```

That produces `dist/ClaudeUsage.app`. Run it:

```bash
open dist/ClaudeUsage.app
```

Install it so it persists:

```bash
cp -R dist/ClaudeUsage.app /Applications/
```

To check the data pipeline without launching the UI:

```bash
dist/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --dump
```

```
Session (5h): 45% · resets at 19h (in 3h03m) · active
Week (all models): 15% · resets Wed 26 at 11h (in 1d 19h)
Week (Fable): 1%
Menu bar would read: 45% · 19h
```

Quit from the dropdown, or `pkill -f ClaudeUsage.app`.

## How it works

The app calls `GET https://api.anthropic.com/api/oauth/usage` — the same endpoint Claude Code's own
`/usage` screen uses — with the OAuth token Claude Code stores in your login Keychain, and renders
the `limits[]` array it returns.

| File | Role |
| --- | --- |
| `KeychainToken.swift` | Reads the access token from the login Keychain |
| `UsageAPI.swift` | The HTTPS call, error typing, and a single retry on 401 |
| `Models.swift` | Wire format, and normalising it into a display model |
| `UsageStore.swift` | The 60-second polling loop and the last-known-good state |
| `StatusItemController.swift` | The `NSStatusItem`, its colours, and the popover |
| `DropdownView.swift` | The SwiftUI dropdown |
| `Formatting.swift` | 24-hour clock, reset phrases, countdowns |
| `LoginItem.swift` | `SMAppService` wrapper for launch-at-login |

It is an `NSStatusItem` + `NSPopover` rather than SwiftUI's `MenuBarExtra`, because a `MenuBarExtra`
label is rendered as a template image and ignores text colour — which would rule out the colour
coding.

### Credentials

**This app does not sign in, refresh tokens, or store credentials of its own.** It reads the token
Claude Code already holds, sends it only to `api.anthropic.com`, and keeps it in memory. Token
refresh stays Claude Code's job; if the token has expired the app says so and points you back to
Claude Code.

It decodes only `accessToken` — never the refresh token — and never logs it, writes it to disk, or
puts it in an error message or a URL.

### Why it shells out to `/usr/bin/security`

Worth knowing, because it is unusual. The app reads the Keychain by spawning

```bash
security find-generic-password -s "Claude Code-credentials" -w
```

rather than calling the Security framework directly.

That is not a shortcut. The Keychain item Claude Code creates has an access-control list granting
read access to exactly one program — `/usr/bin/security` — because that is what Claude Code writes
it with. A direct `SecItemCopyMatching` call from this app is not on that list, and instead of
failing cleanly it opens a **blocking** system password prompt that hangs the app until dismissed.
Because an ad-hoc code signature is pinned to a hash that changes on every rebuild, clicking
"Always Allow" would not survive the next build either.

The practical consequence to be aware of: **the app reads your Claude Code token without macOS
prompting you.** It gets that access because `/usr/bin/security` runs as you, with your rights — it
is not a privilege escalation, and you can run the same command yourself in a terminal. But there
is no per-app consent dialog, which is why the code above is deliberately narrow.

## Menu bar colours

| Usage | Colour |
| --- | --- |
| Below 75% | Normal (adapts to your menu bar) |
| 75–89% | Orange |
| 90% and above | Red |

Dimmed versions of these mean the numbers are real but the last refresh failed.

## Launch at login

The dropdown has a "Launch at login" checkbox backed by `SMAppService`. It works from any location,
so the app does not have to live in `/Applications` — but the registration follows the bundle
identifier, so if you move the app after enabling it, uncheck the box first, move it, then re-check.

If macOS says it needs approval, enable **Claude Usage** under
System Settings › General › Login Items.

## Where it stores things

`~/Library/Application Support/ClaudeUsage/state.json` — the last snapshot and the retry
schedule. Delete it to reset; the app recreates it. Nothing else is written, and no credential
is ever stored.

## Notes

- `spctl -a -vv` reports "rejected" for this app. That is expected for any ad-hoc-signed binary and
  does not block launching — Gatekeeper only blocks apps carrying a quarantine attribute, which a
  locally built app does not have.
- The bundle identifier is set in `build.sh`. Change it there if you want your own.
- **Install it on your internal disk.** Running the app from an external or removable volume
  will crash it with `SIGBUS` the moment that volume sleeps or disconnects, because macOS can
  no longer page in the executable. `cp -R dist/ClaudeUsage.app /Applications/` and run it from
  there.
- This is an unofficial tool and is not affiliated with Anthropic. The usage endpoint is not a
  documented public API and could change.

## License

MIT
