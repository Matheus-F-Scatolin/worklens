# Worklens — Implementation Plan

Worklens is a macOS menu-bar app that periodically screenshots the user's own screen,
turns each screenshot into a short markdown description with a cheap vision model,
and coalesces those into a daily timeline of where time went and where the day
fragmented. (It also wrote daily and weekly reports with a strong model until they were
cut on 2026-10-05, #298.)

It is a personal optimization tool, **not** a surveillance tool. Every design choice
below should make that obvious to anyone reading the code.

---

## 1. Principles

1. **Local-first, single user.** All data lives in one folder on the user's Mac
   (SQLite + JPEGs + markdown). No server, no account, no sync, nothing for a
   manager to log into.
2. **The user holds the kill switch.** Global pause hotkey, per-app / per-title
   blocklist, "delete last 10 minutes", visible menu-bar state at all times.
3. **Text is the product; images are evidence.** Screenshots are kept locally as
   evidence, but every downstream feature works from the text descriptions. Frames
   flagged sensitive by the describer are deleted.
4. **Second person, no judgment.** Worklens says "you spent 2h in Slack", never
   "the subject". No productivity scores, no comparisons to other people.
5. **Cheap by construction.** Change detection + OS metadata avoid most vision
   calls; the vision model is the cheapest one that works. A hard daily USD budget
   stops spending.
6. **Low overhead on the laptop.** Native Swift, no Electron. Target < 60 MB
   *dirty footprint* idle (`footprint -p`, not resident size, which mostly counts
   the shared dyld cache) and negligible CPU between captures — and easing off on
   battery rather than capturing as if the charger were in. What it actually
   measured, and how, is [docs/footprint.md](footprint.md).

---

## 2. Stack (decided)

| Concern | Choice | Why |
|---|---|---|
| Language / build | Swift 6.x, SwiftPM (no Xcode project), Swift 5 language mode | CLT-only machine; SwiftPM is agent-friendly; language mode 5 avoids strict-concurrency compile churn |
| App shell | SwiftUI `MenuBarExtra` + `LSUIElement=true` bundle | Menu-bar-only app, no Dock icon by default; Settings → General can add one (#147) |
| Screen capture | ScreenCaptureKit `SCScreenshotManager` (macOS 14+) | The only non-deprecated path |
| Foreground metadata | `NSWorkspace` + `CGWindowListCopyWindowInfo` + AppleScript for browser URL | Free, no vision call needed |
| Storage | SQLite via GRDB 7.11+ (`DatabasePool`, WAL) | Mature, Codable records, migrations |
| Vision model | Gemini 3.5 Flash-Lite via REST `generateContent` | $0.30/M in, $2.50/M out; structured JSON output; `thinkingLevel: minimal` |
| Global hotkey | Carbon `RegisterEventHotKey` (`App/GlobalHotkey.swift`) | No dependency; `KeyboardShortcuts` 3.x cannot link under CLT (#16) |
| CLI | swift-argument-parser | Headless testing of every stage |
| Tests | Swift Testing (`import Testing`) | Ships with the toolchain; works without Xcode.app |

Deployment target: **macOS 14.0**. Developer machine: macOS 26, Swift 6.3.3, Command Line Tools only.

---

## 3. Where the rest lives

This file is deliberately short so a session can read it whole. The detail is split by the
question you are asking; open only the file you need.

| You need | Read |
|---|---|
| Where a type, table or config key lives; wiring; CLI convention | `docs/architecture.md` |
| The exact Gemini request and response shapes | `docs/api-shapes.md` |
| Why a decision was made; the cost model; milestones; things only the user can do | `docs/decisions.md` |
| How the app shell wires a stack together | `docs/wiring/*.md` |
| The spec for one unit of work | `gh issue view NN` (the original #1–#25 are GitHub issues #1–#25, and in git history) |

Build order is the issue numbering. A useful product exists after #10 (timeline) and a
complete v1 after #18.
