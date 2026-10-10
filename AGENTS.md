# AGENTS.md

Notes for humans and agents working on Blink.

## What Blink is

A menu bar app (NSStatusItem + custom NSPanel) that watches local dev servers
(via `lsof`) and booted iOS simulators (via `simctl`), and lets you kill,
restart, ignore, or focus them. SwiftUI + AppKit, zero third-party
dependencies.

## Building

- Full Xcode is required; Command Line Tools alone have no `xcodebuild`.
  If `xcode-select -p` points at CLT, prefix commands with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` instead of
  changing the global setting.
- Debug build (no signing identity needed):

  ```bash
  xcodebuild -project Blink.xcodeproj -scheme Blink -configuration Debug build \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
  ```

## Signing & distribution — read this first

- **There is no Apple Developer account and there never will be.** No
  "Developer ID Application" certificate, no hardened runtime, **no
  notarization**. Don't try to make `Scripts/release.sh` run end-to-end; it
  intentionally refuses to ship anything that isn't Developer ID signed, and
  that gate can't be satisfied on this machine.
- Release artifacts are signed with the **self-signed `now Developer` login-
  keychain identity** — the same certificate v1.3.0 shipped with:
  `codesign --force --sign "now Developer" build/Blink.app`
- ⚠️ Do **not** ship anything built with `CODE_SIGNING_ALLOWED=NO`. That flag
  leaves the bundle half-sealed: `codesign -dvv` happily says "Signature=
  adhoc", but `codesign --verify --deep --strict` fails with "code has no
  resources but signature indicates they must be present", and Gatekeeper
  shows the hard **"damaged"** dialog that has no Allow Anyway button.
  Always finish with a `codesign --verify --deep --strict` gate before
  building the DMG.
- Consequence for consumers: Gatekeeper still blocks the first launch
  (untrusted chain). Right-click → Open, System Settings → Privacy &
  Security → "Allow Anyway", or `xattr -cr Blink.app` for stubborn cases.

## Ship flow

1. Commit and push `main` — but note the remotes: `origin` is the upstream
   megootronic/Blink (never push there), `fork` is BoThomas/Blink (push here,
   releases live here).
2. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `Blink.xcodeproj/project.pbxproj` (both configurations) so the app's
   About page matches the release tag. (v1.3.0 shipped still claiming 1.2 —
   don't repeat that.)
3. Release build, then hand-sign with `codesign --force --sign "now
   Developer"` and verify (`codesign --verify --deep --strict` must pass),
   then DMG via `Scripts/build-dmg.sh`.
4. `gh release create vX.Y.Z -R BoThomas/Blink --title "Blink X.Y.Z"` with
   the DMG attached as `Blink-vX.Y.Z.dmg`. Tag the fork's main HEAD.
5. Release notes style: `## What's Changed` with `### Fixed` / `### Added` /
   `### Changed` bullets and a `Full Changelog` compare link
   (`vPREV...vNEW`). English, plain, no marketing.

There is no CI — releases are built locally.

## Code conventions

- Commit subjects: short, imperative, no prefix ("Fix shell deadlock when
  process output outgrows the pipe buffer").
- Comments explain *why*, not *what*. Keep that ratio when editing.
- AppState is `@MainActor`; all observable state mutations happen on the main
  thread. Shell outsourcing lives in `Shell.run`; parsing lives in pure
  statics beside it.
- Performance invariants worth preserving (they cost real CPU when broken):
  per-PID resolution is cached (`AppState.serverCache`), `ps`/`lsof` run as
  one batched call for all new PIDs, simulator display names are cached
  forever, and polling is slow (10 s) while the panel is closed.
