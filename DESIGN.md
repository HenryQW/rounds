---
version: alpha
name: Rounds
description: "A native macOS utility in Linear's restraint: system materials and controls, hairlines over fills, colour only where it carries a state, and one brand colour, Rounds blue (#0A6BDB). Orange means a session needs the user, blue means it runs. A drinking pun on the name lives in the tile names and the Another round? banner, never in states or actions."

colors:
  rounds-blue: "#0A6BDB"
  rounds-blue-hairline: "#0A6BDB at 45%"
  icon-top: "#2A86F0"
  icon-bottom: "#0A5CC4"
  attention: "systemOrange"
  attention-ink: "#2B1A00"
  running: "systemBlue"
  ready: "systemGreen"
  failed: "systemRed"
  failed-ink: "#330505"
  muted: "systemGray"
  selection: "controlAccentColor"
  hover: "primary at 8%"
  tile-fill: "primary at 3%"
  tile-selected: "controlBackgroundColor"
  tile-selected-hairline: "primary at 30%"
  hairline: "separatorColor"
  author-link-light: "#1D4ED8"
  author-link-dark: "#8FB3FF"

typography:
  row-title: { font: SF Pro, style: body, weight: medium }
  row-subtitle: { font: SF Pro, style: caption, color: secondary }
  row-time: { font: SF Mono, style: caption2, color: secondary }
  section-label: { font: SF Pro, style: caption, weight: semibold, tracking: "+0.4pt", color: secondary }
  tile-count: { font: SF Pro, size: 15pt, weight: semibold, tracking: "-0.2pt", digits: monospaced }
  tile-total: { font: SF Pro, size: 11pt, weight: medium, color: secondary }
  tile-name: { font: SF Pro, style: caption, color: secondary }
  pill-count: { font: SF Pro, size: 14pt, weight: semibold, tracking: "-0.2pt", digits: monospaced }
  page-title: { font: SF Pro, size: 20pt, weight: semibold, tracking: "-0.4pt" }
  page-summary: { font: SF Pro, style: callout, color: secondary }
  keycap: { font: SF Pro, size: 11pt }

rounded:
  xs: 4pt
  sm: 6pt
  md: 8pt
  pill: 12pt
  capsule: full

spacing:
  xxs: 4pt
  xs: 8pt
  sm: 12pt
  md: 16pt
  lg: 24pt
  edge-bars: 16pt
  edge-rows: 40pt
  edge-titles: 82pt

components:
  pill-idle: { size: 28x100pt, shape: "square on the screen side, 12pt round inside", fill: clear glass, hairline: "primary at 25%, 1pt" }
  pill-running: { fill: "{colors.rounds-blue}", hairline: "black at 30%, 0.5pt", content: "the running count over a drink (black at 18%, 60% high) with two white fizz bubbles that rise" }
  pill-ready: { fill: "{colors.ready}", ink: "#062910", content: "a still wine glass over the Your Turn count", motion: "none" }
  pill-attention: { fill: "{colors.attention}", ink: "{colors.attention-ink}", content: "a cocktail shaker over the count", motion: "peek 12pt, ring and the shaker shakes every 2s" }
  pill-failed: { fill: "{colors.failed}", ink: "{colors.failed-ink}", content: "a broken glass over the count", motion: "peek 12pt, red ring; the glass is whole, shakes and breaks every 2s" }
  tile: { height: 44pt, rounded: "{rounded.md}", fill: "{colors.tile-fill}", hairline: "{colors.hairline} 0.5pt", content: "state-coloured symbol, count, tile name" }
  tile-selected: { fill: "{colors.tile-selected}", hairline: "{colors.tile-selected-hairline}" }
  source-toggle: { height: 28pt, rounded: "{rounded.capsule}", hairline: "{colors.hairline} 0.5pt", content: "source icon 20pt and count" }
  another-round-banner: { place: "the empty Last Call list (ContentUnavailableView)", icon: "🍹 at 40pt", title: "Another round? in {colors.rounds-blue}", buttons: "one per source that is on: 20pt source icon and name, 32pt high, {rounded.md}, {colors.rounds-blue-hairline}, grey hover fill" }
  row: { insets: "8pt by 4pt", rounded: "{rounded.sm}", content: "status dot, source icon 18pt, title and subtitle, a glass (12 by 14pt) that fills when working, time and PR mark" }
  row-hover: { fill: "{colors.hover}" }
  row-selected: { fill: "{colors.selection}", text: white }
  status-capsule: { rounded: "{rounded.capsule}", hairline: "{colors.hairline} 0.5pt", content: "6pt state dot and words" }
  keycap: { padding: "6 by 2pt", min-width: 20pt, rounded: "{rounded.xs}", hairline: "{colors.hairline} 0.5pt" }
  settings-sidebar: { width: 230pt, head: "app icon 32pt, name, version", foot: "Report a Bug, author signature" }
---

## Overview

Rounds is a background utility, so its design gets out of the way. It uses native SwiftUI and AppKit parts with default styling first: the glass toolbar, the search field, the sidebar, grouped forms and system colours, which follow the light and dark appearance. On top of that it takes Linear's restraint: hairlines in place of grey fills, one place for colour, tight tracking on numbers and titles, and a 4 pt spacing scale.

## Colors

Colour is information. Orange means a session needs the user, blue means it runs, green means a result is ready (the pill turns green, still, while only unseen results wait: Ready, Finished, Stopped), red means a failure, grey means nothing to do. The Served tile is the one exception: its symbol is green, for drinks served. The PR mark takes GitHub's colours on its symbol only: green open, purple merged, grey closed (not red, which means a failure). Hover is a grey fill and selection is the system accent, and the two never look alike.

Rounds blue (#0A6BDB) is the one brand colour: the app icon (a white glass two-thirds full, with an orange bubble), the running pill and the Another round? banner. White text on it keeps about 5:1; system blue gives about 4:1, which is too low. The author link uses henry.wang's Decisive Cobalt (#1D4ED8), or its Evidence Blue (#8FB3FF) in dark mode.

## Typography

System fonts only (SF Pro, SF Mono). Counts and titles take a small negative tracking; section labels take +0.4 pt, as taxonomy rather than titles. Times and PR numbers are monospaced, so columns do not jump. Tile names are drinking puns (Last Call, On Tap, Served, Aged); their plain names (Your Turn, Running, Quiet, Older) are in the hints and VoiceOver. Copy follows ASD-STE100 Simplified Technical English, with no em or en dashes.

## Layout

The session window has three left edges: 16 pt for the filter bar, the section icon, the chevron and the bottom bar; 40 pt for the section name and the row dot under it; 82 pt for the row title, where child rows start. Hover and selection fills start 8 pt from the window edge. Every gap comes from 4, 8, 12, 16 or 24 pt. The window fits its rows in one step, with no height animation; slides move only the origin.

## Elevation

Flat. Depth comes from the system's glass toolbar and from hairlines (0.5 pt separator). No drop shadows and no gradients, except in the app icon.

## Motion

Only live work moves, and it moves like a round of drinks. A working row shows a small glass that fills to 80 %, stays full and empties to 10 %, 2.4 to 3.2 s a pour at 20 frames a second, each glass with its own speed and start. The running pill is a glass two-thirds full, with fizz that rises behind the count. The attention pill shakes a cocktail shaker as it peeks 12 pt out every 2 s with an orange ring; the count stays still. While a failure waits the pill is red, and its glass shakes and breaks at each peek. A Failed row shows the broken glass, still. With Reduce Motion, nothing moves.

## Do and Don't

- **Do** use a native control before a custom one.
- **Do** show a state with its colour on a small mark (a dot, a symbol), not a filled card.
- **Do** keep puns to the tile names, the banner and the motion.
- **Don't** add a second brand colour, a gradient or a shadow.
- **Don't** let hover and selection look alike.
- **Don't** put a pun on a state or an action: status words must read at a glance.

## Differences from Linear

Linear's marketing system is dark only, with one lavender accent. Rounds follows the system appearance and keeps several state colours, because in Rounds colour is information. It takes from Linear the restraint, the hairlines, the tracking and the spacing scale.
