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
- [ ] DD-01 — Design system: tokens (spacing, radii, typography, semantic colors), components
  (SettingsTile/icon tile, StatusBadge, Keycap, SectionCard, PreviewCanvas), snapshot renderer.
- [ ] DD-02 — Shell + sidebar + Overview dashboard (live workspace miniature).
- [ ] DD-03 — Settings sections redesign (Layout, Animations, Focus ring, Rules) with previews.
- [ ] DD-04 — Shortcuts, Logs, Diagnostics redesign.
- [ ] DD-05 — Onboarding (permissions), menu bar status item, launcher panel.

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
