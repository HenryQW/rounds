# AGENTS.md

Rounds: a native macOS 27 background app that shows the live state of AI coding sessions (Claude desktop, Codex, herdr agents) in an edge drawer. Read this file first; open the spec only for the section you need.

## Where things are

| Need | File |
|---|---|
| What to build and why | `docs/spec.md` (§2 data sources, §3 classification, §5 UI) |
| Look: colours, type, spacing, components | `DESIGN.md` |
| Words and their meaning (the standard states) | `GLOSSARY.md` |
| Release notes, one section per version (website/docs/release.md) | `CHANGELOG.md` |
| Resumable state (git-ignored) | `.context/progress.md` |

Code: `Sources/RoundsCore` (models, parsers, classifier, hook settings; no UI), `Sources/Rounds` (app), `Sources/rounds-hook` (hook helper that Claude Code and Codex run). Tests: `Tests/RoundsCoreTests`.

## Build and test

- `scripts/test.sh`: the only way to run tests (it passes the Swift Testing plugin path).
- `scripts/bundle.sh --install`: builds, signs and copies `Rounds.app` to `/Applications`. It signs with "Rounds Self-Signed" when the login keychain has it, else ad hoc. An ad hoc build is a new app to macOS, so the Keychain (the Linear key, push values) and permissions ask again after each install; the user imports the release `.p12` from 1Password once (`security import <file> -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign`) to stop that. Relaunch with `pkill -x Rounds; open "/Applications/Rounds.app"`.
- Linker "search path ... not found" warnings are harmless toolchain noise.

## Toolchain and platform traps

- Command Line Tools only, no SwiftUI macro plugin: `@State` does not compile. View state lives in `@Observable` classes.
- `NSApp` is nil in `App.init`; make windows after launch (`DispatchQueue.main.async`).
- SwiftUI's `Settings` window has no resizable style, whatever `windowResizability` says; the view adds `.resizable` to its window.
- A grouped `Form` makes `LabeledContent` values selectable text; the Settings form sets `.textSelection(.disabled)`.
- `proc_pidinfo` cannot read root processes (such as `login` between a terminal and its shell); read parents with `sysctl` `KERN_PROC_PID`.
- A hover on a non-activating panel gives no focus; the cooperative `NSApp.activate()` leaves the other app in front.
- A spring's slow tail leaves a window visible at the end of a slide off the screen; slides off the screen use an ease-in.

## Rules for changes

- Design changes: when the user asks for a design change, show up to three mockups to choose from, with one marked as recommended. Fewer than three is fine when fewer real options exist. Build only after the user picks one.
- Smallest change that follows the existing code; match comment density and naming.
- Native SwiftUI and AppKit components with default styling first.
- Colour is information: orange means needs input, blue means running; hover is grey and selection is the accent, and the two never look alike.
- Update the spec in the same commit as a behaviour change.
- Docs and UI copy: ASD-STE100 Simplified Technical English, no em or en dashes.
- Commit each change; never push without the user's go-ahead.
- Release notes: before the tag, a cheaper model (in Claude Code, a Sonnet subagent, `model: "sonnet"`) drafts the version's `CHANGELOG.md` section from `scripts/release-notes.sh v<previous> HEAD HenryQW/rounds` and the rules at the top of `CHANGELOG.md`. The main agent checks the draft against those rules, shows it to the user, and commits it with `VERSION` (website/docs/release.md).

## UI rules (all windows, menus, hints and docs)

- Names say what a setting does ("Close the window after", not "Slide back after"). Each setting row has a one-line explanation under its name in the secondary colour (`described` in SettingsView); footers are only for errors and one hint for the whole section. All setting labels on every tab share one maximum width (`labelColumn()`), so labels and controls read as two columns, except the Agents and Tickets pages, whose integration rows take the full width.
- Capitals: Title Case for buttons, menu items, picker options, tab names and window titles ("Select All", "Repair Hooks", "Change Key…", "Double-Click"); sentence case for setting names, toggle and checkbox labels, explanations, hints and status text ("Open at login", "Not installed").
- Say each fact once. Do not repeat what a filter, a section or a colour already shows (no state word under a status filter; no "seen" word next to a ring dot).
- Hierarchy reads left to right: a child starts under its parent's title; a parent shown only for context is grey, with no dot, and cannot be selected.
- Every control that reacts to a click shows the grey hover fill, like the rows.
- A state the user must act on shows in the pill; a state the user has seen does not alert again (seen: ring dot).

## Running and checking the app

- Screenshots: window only (`screencapture -x -o -l <window id>`, id from `CGWindowListCopyWindowInfo`); never the full screen; delete after review.
- A session window that changes size by itself: follow `.claude/skills/watching-window-frames/SKILL.md` (`scripts/watch-frames.sh` flags abnormal resizes from the `frame` debug log).
- Never send keys or move the pointer while the user is active (check `HIDIdleTime`), and stop automatic checks while the user tests by hand.
- The global shortcut may be empty on purpose (a stored `null`); restore it after a temporary change.
- Never touch `~/.claude/settings.json` or `~/.codex/` except through the app's Settings install, which previews and keeps a backup.
