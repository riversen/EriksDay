# EriksDay

A private iOS app for logging Erik's day. Data lives in a shared iCloud Drive folder you own and
control; family members log from their own devices by pointing the app at the
same folder.

This first iteration is a working vertical slice: pick the folder, tap to log an
event, see today's entries, and have them sync via iCloud. The rest is on the
roadmap in `CLAUDE.md`.

## What you need

- A Mac with Xcode (current version).
- Homebrew.
- The iPad (and any other device) signed into the Apple Account that should own
  the data — most likely yours.
- An Apple Developer Program account for signing (you have this).

## 1. Generate the Xcode project

```
brew install xcodegen
cd EriksDay
xcodegen generate
open EriksDay.xcodeproj
```

`project.yml` is the source of truth for the project; `EriksDay.xcodeproj` is
generated from it and is git-ignored.

## 2. Set signing

In Xcode: select the `EriksDay` target, Signing & Capabilities, turn on Automatic
signing, and choose your team. To keep this across regenerations, also set
`DEVELOPMENT_TEAM` in `project.yml` (your Team ID is in Xcode > Settings >
Accounts, or at developer.apple.com/account). Change
`PRODUCT_BUNDLE_IDENTIFIER` from `com.example.eriksday` to your own.

No iCloud capability is required. The app reaches the folder through the file
picker and a security-scoped bookmark, not through an app entitlement.

## 3. Create the shared folder

On the Mac (Finder) or iPad (Files), in iCloud Drive:

1. Make a folder, e.g. `EriksDay`.
2. Share it: right-click > Share > Collaborate (or Files > Share in iOS),
   invite family, set access to "Can make changes".

## 4. Run it

Build and run on the iPad (or the Simulator). On first launch tap **Choose
Folder** and select the shared `EriksDay` folder. Each person does this once on
each of their own devices.

## 5. Continue building with Claude Code

Install Claude Code (native installer, no Node needed):

```
curl -fsSL https://claude.ai/install.sh | bash
# or: brew install --cask claude-code
claude --version
```

Then work in this directory:

```
cd EriksDay
claude
```

`CLAUDE.md` gives Claude Code the architecture, the storage rules, and the
roadmap so each session stays consistent.
