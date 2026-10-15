# Desktop app design: elegant, native, minimal

## Objective
Give the Gio desktop app (main window, menu bar, launcher) a polished, Apple-native look and
feel: elegant, minimal, calm, with excellent UX — on par with macOS System Settings / first-party
utilities (the "iOS-like" feel the user asked for, done the macOS way).

## Problem
User (2026-09-30): "hay que darle más amor al diseño de la desktop app, está muy básica,
necesitamos algo bonito, algo propio de iOS, elegante, minimalista con muy buen UX/UI".
Current GioUI (≈2.5k lines): plain NavigationSplitView sidebar with text rows, default Forms,
monospaced diagnostic text, basic keycaps, plain launcher window, text-only menu bar item.

## Design direction
- Native vocabulary: macOS 14/15 System Settings style — translucent sidebar (material), SF Symbol
  icons in rounded-square colored tiles, grouped `Form` sections (`.formStyle(.grouped)`), section
  headers/footers with concise explanations, toolbar titles, generous spacing, SF Pro / rounded
  numerals, semantic colors only (light + dark mode), accent from the focus-ring color.
- Overview as a dashboard: status tiles (permissions, session, workspaces, windows) with clear
  states, a live miniature of the current workspace strip (columns, focused column, parked
  columns) rendered from the session snapshot.
- Shortcuts: grouped cards, beautiful keycaps (rounded, subtle bezel), search, category chips.
- Layout / Animations / Focus ring: live previews (gap/padding/width preview, spring curve
  preview animating a sample tile, ring color swatch on a sample window), sliders with value
  labels, reset-to-default per section, inline validation.
- Rules: list with app icons (NSWorkspace icon for bundle/app name), add/edit sheet.
- Logs / Diagnostics: readable, filterable log list with level pills; diagnostics as a checklist
  with actions as proper buttons.
- First-run onboarding: welcome + Accessibility (and optional Screen Recording) permission steps
  with clear "why" and live status.
- Menu bar: SF Symbol status item with workspace indicator; tidy menu.
- Launcher: Spotlight-like floating panel (vibrancy, large search field, result rows with icons,
  keyboard navigation, subtle animation).
- Accessibility: VoiceOver labels, keyboard navigation, Reduce Motion / Increase Contrast respected.

## Scope (authorized)
Visual/UX redesign of GioUI + menu bar + launcher presentation; no behavior changes to the WM.

## Constraints
- UI code in GioUI (no pbxproj edits); AppKit/SwiftUI on main; never block main on the session
  queue (use existing snapshot/push paths); idle policy (no timers when hidden) preserved.
- Pure view models stay tested (XCTest); visual verification via rendered snapshots
  (ImageRenderer → PNG in the scratch dir) reviewed by the parent before commit.
- Conventional Commits, NO Co-Authored-By; push after verified batches; no PR.

## Tasks
- [x] DD-01 (`f32b592`) — Design system: tokens (spacing, radii, typography, semantic colors), components
  (SettingsTile/icon tile, StatusBadge, Keycap, SectionCard, PreviewCanvas), snapshot renderer.
- [x] DD-02 (`768af38`) — Shell + sidebar + Overview dashboard (live workspace miniature).
- [x] DD-03 (`a90f92e`) — Settings sections redesign (Layout, Animations, Focus ring, Rules) with previews.
- [x] DD-04 (`7d36324`, `fa7867f`) — Shortcuts, Logs, Diagnostics redesign.
- [x] DD-05 (`29faaa3`) — Onboarding (permissions), menu bar status item, launcher panel.

Evidence DD-01/02 (route: delegated writer, opus): tokens + components (SectionIcon, StatusBadge,
Keycap, SectionCard, MetricTile, PreviewCanvas), accent contrast; unified-toolbar shell, sidebar
groups with icon tiles, Overview dashboard (metric tiles, live strip miniature from session
layout, status card, workspace pills, windows by workspace). RED compile -> GREEN; bundles
45/7/19/39/1088 all 0 failures (parent re-ran); signed build OK. Parent reviewed light/dark PNGs:
polished; follow-up: dark-mode active workspace pill (white text on light accent) low contrast.
ImageRenderer can't render sidebar material/ScrollView (stand-ins). LIVE PENDING.

Evidence DD-03 (route: delegated writer, opus): settings split into Layout / Focus (new sidebar
entry) / Animations / Rules with live previews (layout mini display + preset ticks, motion tile +
spring curve from Spring math, focus indicator samples, rules with app icons), Apply bar with
dirty state + ⌘S/⎋, toasts, Reset Section; accent text contrast >=4.5:1 (729-colour sweep).
RED compile -> GREEN; bundles 91(20 skipped)/7/19/39/1120 all 0 failures (parent re-ran);
signed build OK. Parent reviewed PNGs: polished. Follow-ups: stale "ring in fullscreen" footer
under Match gaps, preset widths shown as raw text (use chips), unsaved edits lost on section
switch without warning. LIVE PENDING.

Evidence DD-03 follow-ups + DD-04 + DD-05 (route: delegated writer, opus): preset chips, per-section
drafts with sidebar dot, corrected fullscreen/ring copy; Shortcuts (search ⌘F, category chips,
cheat sheet, config tag), Logs (level pills, ×N grouping, pause/follow), Diagnostics (6 checklist
cards, toolbar actions, toasts); onboarding sheet (welcome, Accessibility live status, optional
Screen Recording, keys), menu bar template glyph with workspace badge + redesigned menu, launcher
Spotlight-like non-activating panel (vibrancy, ↑↓⏎⎋ ⌘1-9). RED compile each (one helper test
written after code — noted). Bundles 158(42 skipped)/7/19/39/1120 all 0 failures (parent
re-ran); signed build OK. Parent reviewed PNGs (shortcuts, onboarding, launcher): polished;
launcher PNG grey veil is an offscreen icon-render artifact. LIVE PENDING. ALL DD TASKS DONE.
- [x] DD-06 (`05b822f`) — Live test: Alt+Space showed nothing; `gio restart` → command not found.
  No definite root cause (defensive): orderFrontRegardless + makeKey + first responder, 250ms
  resign-key grace, generation tokens vs stale fade-out, alpha safety deadline, slide pin fix;
  lifecycle logs `launcher summon source= / shown key= / dismissed reason=`. Diagnostics "Command
  Line" card symlinks ~/.local/bin/gio -> built GioCLI (dev builds) or shows the command. Bundles
  174(42 skipped)/7/19/39/1141 all 0 failures (parent re-ran); signed build OK. LIVE PENDING.
  Live round results: #5 menu bar OK, #6 workspaces OK (user), #2 dark/light follows system (no
  in-app toggle), #9 not run (my table-escaped `\|` broke the command).
- [x] DD-07 (`18e3f98`) — Gio's own identity, taken from the landing page (`gio-landing`). User
  (2026-10-14, Overview screenshot): "hay que ajustar el UI a lo que tenemos o a lo que representa
  Gio, algo como lo hiciste en la landing". Supersedes DD-01's "semantic system colors, accent from
  the focus-ring color". Tokens (`DesignTokens.swift`): `GioBrand` (the mascot's palette: navy ink,
  cream paper, mint, butter, coral, sky, lilac, the landing's hex values); `GioColor` page / sidebar
  / card / raised / well / hairline / text in navy (dark) and cream (light); status hues are the
  spots (ok mint, warning butter, error coral, info sky) with `okInk` / `warningInk` / `errorInk` /
  `infoInk` for text (the system-color `ink(_:)` is gone); `accent` / `onAccent` for controls;
  `tintFill` (pastel spot) vs `tint` (deeper on cream) per `SectionTint`. App accent is the brand
  mint (`GioBrand.accent`, the `gioAccent` default); the focus ring keeps its configurable color on
  screen (Alt+O overview still uses it). Components: `SectionIcon` = navy glyph on a pastel spot
  tile, keycaps like the landing's `<kbd>`, `GioSwitch` / `GioSlider` / prominent buttons
  (`BrandProminentButtonStyle`, navy/cream text on mint) / launcher selection in the accent, page
  titles in SF Pro Rounded with a section number pill (`SectionNumberPill`, `sectionNumber`, the
  landing's `2 · The strip` labels), Overview tile mint and Diagnostics sky. Mascot: GioUI resource
  `gio-mascot.png` (landing art downscaled to 403x440), `GioMascot` in the sidebar header and the
  onboarding welcome ("Hi, I'm Gio." with the landing's squiggle, spot-tile value points);
  `GioAppMark` removed. Fonts stay system (Bricolage/Figtree not bundled). Evidence: every
  `GioUITests` snapshot rendered light and dark (106 PNGs) and reviewed (window, onboarding, layout,
  logs, components); full `swift test` UI 310 (53 skipped) / Session 477 / POC 7 / Mac 19 / MacOS
  95 / Core 1970, 0 failures; signed `xcodebuild` BUILD SUCCEEDED, `Gio_GioUI.bundle` with the
  mascot inside `Gio.app`, `codesign --verify --deep --strict` OK. Not verified live: the real
  sidebar's selection color (`.tint` on the `List`; AppKit may keep the system accent).

## Acceptance criteria
- Every section rendered to PNG (light + dark) and reviewed; consistent tokens; no regressions.
- All 5 bundles green; signed build OK.

## Applicable checks
- TDD: STRICT ON for view models/pure logic. Runner `swift test` (5 bundles).
- Signed build: `xcodebuild -project Gio.xcodeproj -scheme Gio -configuration Debug -derivedDataPath .build/GioAutoTeam -destination 'platform=macOS,arch=arm64' DEVELOPMENT_TEAM=2CAK428VHF build`.

## Routes
DD-01..DD-05 delegated writers, sequential, after the in-flight native-zoom fix lands.

## Progress
- 2026-09-30: document created. Waiting for native zoom fix writer; then DD-01 + DD-02.
- 2026-09-30: DD-01 + DD-02 done, pushed. Next: DD-03 (after focus-indicator decision).
- 2026-09-30: DD-03 done, pushed. Next: DD-04 + DD-05 (+ DD-03 follow-ups).
- 2026-09-30: DD-04 + DD-05 done, pushed. Next: user live review of the redesigned app.
