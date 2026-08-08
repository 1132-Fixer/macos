# AGENTS.md

## Project
- Name: `1132 Fixer`
- Type: macOS SwiftUI executable (Swift Package Manager)
- Minimum platform: `macOS 13`

## Repository Layout
- `Package.swift`: package definition and executable target config
- `Sources/1132Fixer/1132FixerApp.swift`: app entry point
- `Sources/1132Fixer/ContentView.swift`: UI + command execution logic
- `Sources/1132Fixer/Resources/AppIcon.png`: app icon resource

## Development Commands
- Run app: `swift run`
- Debug build: `swift build`
- Release build: `swift build -c release`
- Release binary: `.build/release/1132 Fixer`
 
## Quick Summary
- **Versioning:** Update `VERSION` for code changes; avoid duplicate bumps.
- **Compatibility:** Target Swift 5.9 and macOS 13; use SwiftUI for UI work.
- **Validation:** Run `swift build` and `swift run` as appropriate before committing.

## Compatibility Requirements
- Keep code compatible with Swift 5.9 and macOS 13 APIs.
- Keep UI changes in SwiftUI and follow existing visual/component patterns.

## Design System
- `design-system/` is a git submodule (`https://github.com/PrimeUpYourLife/1132-fixer-design-system.git`) and the source of truth for all design decisions.
- For any design matter — colors, typography, spacing, components, icons, visual patterns — consult `design-system/` first and follow its tokens/components.
- Do not invent new visual patterns, colors, or component styles that diverge from `design-system/`.
- If `design-system/` lacks guidance for a needed case, ask the user before improvising rather than guessing.
- Run `git submodule update --init --recursive` if `design-system/` appears empty.

## 1132 Fixer Zoom Launch Rules

- Zoom must always run in sandbox mode.
- Normal Zoom launch mode does not work for this app and must not be restored.
- Do not add fallback logic that launches Zoom outside sandbox mode.
- Camera settings must remain compatible with sandbox mode.
- Any future changes touching Zoom launch, restart, repair, camera permissions, or camera settings must preserve sandbox-mode behavior.

## Code Review Guidelines
- Prefer small, focused changes over broad refactors.
- Preserve existing behavior unless the task explicitly specifies which behavior to change and how.

## Safety Notes
- The app executes shell commands that can require admin privileges (`osascript` + `sudo`) and launch Zoom with `sandbox-exec`.
- Treat command/script edits as critical; verify quoting and escaping to prevent syntax errors or security vulnerabilities.
- Do not weaken or remove guardrails in scripts unless explicitly requested.

## Validation
 - After edits, run at least: `swift build`.
 - If UI or runtime behavior changed, also run: `swift run` and verify no immediate startup errors.
 - If `swift build` or `swift run` fails, analyze the error message, fix syntax or dependency issues, and retry the relevant command.

Escalation guidance:

 - **If issues persist after troubleshooting:** Collect build and runtime logs, the exact commands you ran, and the changes you made, then open an issue or contact the project maintainer with that information.
 - **Troubleshooting help:** When opening an issue, include `swift build`/`swift run` output, Xcode/Swift toolchain versions, and steps you already attempted to resolve the problem.

## Agent Workflow
- Read this file before making changes.
- Prefer minimal diffs and keep unrelated files untouched.
- Keep `README.md` clean with basic information and usage instructions; avoid adding development details there.
- If unsure about a change's impact, ask for clarification before proceeding.