# SketchyBar contributor instructions

## Before the next feature

Read `~/.agents/skills/write-swift/SKILL.md` completely before adding or changing a feature. Apply its Swift principles, not just its syntax suggestions. If the skill is unavailable, report that and follow the project rules below. Check `xcrun swiftc --version` and the installed SDK before adopting a language feature or API.

For interface or motion changes, also read `~/.agents/skills/apple-design/SKILL.md`. Preserve the existing appearance unless the user requests a design change.

## Swift rules that carry forward

- Start with concrete value types and immutable properties. Use enums for closed sets and mutually exclusive states. Classes need a reason such as AppKit inheritance, identity, or resource ownership. Do not add protocols or generic frameworks speculatively.
- This helper is an AppKit application, not a general-purpose library. `plugins/popup.sh` builds it in Swift 6 mode with complete concurrency checking, main actor isolation by default, and Approachable Concurrency. Keep these settings enabled. Changes to the build script must invalidate the cached executable.
- Keep UI, calendar state, and `EKEventStore` on the main actor. Start synchronously. Use async SDK APIs for waiting. Profile before moving work to `@concurrent` or a separate actor. Never share an EventKit store or mutable SDK objects between execution contexts.
- Use a task only when the operation needs one. UI-root tasks need an owner and cancellation policy. Recheck state after `await`. Prefer structured child tasks. Do not add `Task.detached`, dispatch queues, `@unchecked Sendable`, `nonisolated(unsafe)`, or `@preconcurrency` just to silence diagnostics.
- `MainActor.assumeIsolated` needs a documented delivery guarantee. The existing timer is installed on `RunLoop.main`. EventKit notifications can arrive elsewhere and must enter the main actor before accessing UI state.
- Retain framework delegates through an explicit owner. Do not rely on lexical scope, weak callbacks, or optimizer-dependent lifetimes. Remove observers, invalidate timers, and cancel owned tasks during shutdown.
- Validate external input at boundaries. Throw recoverable errors with context. Use preconditions only for programmer mistakes. A force unwrap needs a stated invariant. Preserve existing user-facing wording unless a wording change is requested.
- Decode popup commands and network kinds into enums. Exhaustive switches must force new features to handle both opening and refreshing. Convert to strings only at shell, JSON, or distributed-notification boundaries. Distributed notifications are cross-process messages, not local typed NotificationCenter messages.
- Keep unsafe memory access inside the CoreAudio and system-call boundary. Audio scalar reads and writes require `BitwiseCopyable` values. Keep pointers scoped, release allocated buffers with `defer`, and use Address Sanitizer when changing this boundary.
- Use `Logger` from `os` for diagnostics and keep personal data private. The JSON output of `notch` and the `<item>_state` trigger variables are machine interfaces, so keep diagnostic text out of them.
- Use the system frameworks already present. Ask before adding a package. The existing Foundation `Process` usage is not permission to install Subprocess or another dependency.

## Existing project boundaries

- The only bar and configuration live in this repository. Never create another configuration, bar instance, copied checkout, or parallel implementation.
- `sketchybarrc` creates bar items. `theme.sh` owns colors, layout, and motion. Shell plugins source it and run under `/bin/bash` 3.2. No associative arrays.
- `plugins/popup.swift` owns the native popups and system snapshots. `plugins/popup.sh` supplies the environment and compiles the helper. `plugins/status.sh` renders bar status. If adding a Swift source file, update the build inputs and rebuild detection in the same change.
- Keep bar blur disabled. Respect Reduce Motion. Use `SIZE_ANIM` and `COLOR_ANIM` for shell animations. Popups share the existing material, 12 pt corners, and measured item anchors.
- Explicit item widths ignore padding. Bracket backgrounds include outer padding. Measure actual geometry rather than guessing. Verify any new SF Symbols codepoint against `/Library/Fonts/SF-Pro.ttf` and keep bar glyph byte escapes in `plugins/status.sh`.
- Commit and push each completed change to this repository's existing origin. Do not overwrite unrelated edits or force-push a shared branch.

## Prove the change on the real bar

Never write unit tests, integration tests, or mocks. Write another kind of test only when the user explicitly asks, using real code and saving its output in the project. This overrides the skill's testing section. Do not create extra documentation unless requested.

Run `plugins/popup.sh build` and the real affected command or popup. Popups must also be checked through actual bar clicks, not only from a terminal: process ancestry and calendar permission attribution differ. Synthetic clicks take over the user's cursor while they work, so keep them rare. Read the item bounds first and plan one pass that covers every case. Run that pass once and then move the cursor back to where it was. Do not click again to retry a step that passed, to take a screenshot, or to check state that `sketchybar --query` or the window bounds can show. Click only the popups the change affects. If a step fails, find the cause from the code, logs, and window bounds before clicking again. Press Escape only while a popup window is confirmed open, because otherwise it reaches the user's front app. Dismiss with a click on an empty part of the bar, never on an app window. macOS `pgrep` needs `-a` to find SketchyBar when it is an ancestor. Check shell syntax with `/bin/bash -n` and the diff with `git diff --check`. Do not disable compiler safety settings to make a feature build.

Restart the existing service with:

```sh
launchctl kickstart -k gui/$(id -u)/dev.mise.sketchybar
```

Use `sketchybar --query <item>` for item bounds and the native window bounds for popups. Capture the right end at `-R2648,0,360,50`, extending the height when inspecting a popup. The single pass covers opening, switching popups, outside click dismissal, Escape, and behavior after a restart. For all three popups that is six clicks and one Escape: volume, network, clock, empty bar, volume, then restart while it is open, then clock and Escape. Take screenshots while the pass has a popup open, not with extra clicks. Do not change live network connections or calendar data just to demonstrate a code change. Delete screenshots and all scratch artifacts when finished. Leave one running bar and a clean, pushed working tree.
