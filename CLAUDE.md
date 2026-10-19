# CLAUDE.md

Context for working on this repository. Read this before changing anything.

## What this is

An Omarchy 4 shell plugin (bar card) plus a CLI and user service that give detachables a tablet mode: auto-rotation, an on-screen keyboard (wvkbd) and touch tweaks when the keyboard comes off. `tablet-mode disable` returns the system to plain Omarchy. It was built on the maintainer's ROG Flow Z13 (GZ302EA). It is deliberately standalone; the user chose not to depend on Omarchy's unmerged rotation PRs (omacom/omarchy #7493, #13531).

| Path | Role |
|---|---|
| `manifest.json` | `alanroman117.tablet-mode`, kind `bar-widget` |
| `Widget.qml` | Bar icon + card on Omarchy's `Panel` + `KeyboardPanel` (the same pattern as alanroman117.amd-npu). IPC target `alanroman117.tablet-mode`: `open`, `close`, `toggle`, `refresh`. Watches `$XDG_RUNTIME_DIR/omarchy-tablet-mode/state.json` |
| `bin/tablet-mode` | Everything else: setup, the daemon, event readers (`_sensor-reader`, `_usb-reader`, `_hypr-reader`), restore and doctor. Sourceable: tests source it for its functions |
| `systemd/omarchy-tablet-mode.service` | Template; `enable` swaps `@BIN@` for the script's path. `ExecCondition=… enabled`, `ExecStopPost=… restore --quiet` |
| `test/run.sh` + `test/fixtures/` | Dry-run suite (`TABLET_MODE_DRYRUN=1`): fake hyprctl JSON, actions logged instead of done |
| `scripts/suspend-test.sh` | Diagnostic for the suspend hang: one scenario per run (`sensor`, `detached`, `detached-sensor`, `osk`; `--rehearse` = `pm_test=devices`), with the plugin off and pm_trace on. It leaves a breadcrumb that survives a hard reset; `report` reads it after a reboot |
| `packaging/wvkbd-deskus/` | PKGBUILD and 3-line layout patch for the US desktop on-screen keyboard (deployed with the plugin so `install` can build it) |
| `scripts/deploy.sh` | Copies the runtime files (`manifest.json`, `Widget.qml`, `bin/`, `systemd/`, `packaging/`, `README.md`, `LICENSE`) into `~/.config/omarchy/plugins/alanroman117.tablet-mode/`, removes anything else there, refreshes an installed unit and restarts the service |

This repo (`~/Github/my-projects/omarchy-tablet-mode-asus-rog-flow-z13`) is the source of truth. Edit here, run `test/run.sh`, then `scripts/deploy.sh`. Never edit the plugin folder directly: deploy overwrites it.

## Rules that matter

- **Every live change has a marker and an undo.** `$RUN_DIR/rotated` (output + original transform), `touch-mapped` (device names), `tweaks.lua` (an `hl.config` that restores the snapshot). `restore_live` undoes exactly those, is idempotent, and runs on daemon exit, `ExecStopPost`, `disable` and `restore`. A new feature needs its marker and its undo in the same change, plus a `doctor` check.
- **Never edit `monitors.lua` and never `hyprctl reload`.** The maintainer's `monitors.lua` relies on live per-display DPI that a reload would throw away. Everything goes through `hyprctl eval`.
- **Rotation replays the panel's mode, position and scale with the new transform.** A transform-only `hl.monitor` resets the scale. Hyprland reports the unrotated `width`/`height` while rotated, so `monitor_geometry` can be replayed as is (verified on 0.56.2).
- **Touch and pen get `hl.device({ name, transform, output })` explicitly.** Following the monitor is unreliable (Hyprland #3538). Device names go through `lua_str` (escaping, no control characters). Output names must match `^[A-Za-z0-9._-]+$`.
- **Gap options read back from `getoption -j` as `"css": "5 5 5 5"`, but must be restored as a `{ top, right, bottom, left }` table.** A string is rejected.
- **Signal traps and `IFS= read`:** a TERM that lands during the main loop's `IFS= read` runs the EXIT trap with that empty IFS in effect. `daemon_exit` resets IFS first. Without it, `read mode pos scale cur` collapses and the panel was never un-rotated (the tests caught this).
- **Background groups start through `spawn_group`,** which makes the process record its own pid. Never use `setsid cmd &` plus `$!`: setsid(1) forks when it is already a group leader, `$!` then names a dead wrapper, and `kill -- -PGID` silently misses (seen 2026-10-05). The readers and the sleep inhibitor are their own group leaders, so `kill -- -PGID` takes the whole pipeline down. The daemon holds the FIFO open read-write, so it never sees EOF between writers.
- **Nothing touches the sensor hub across a suspend.** On 2026-10-05, suspending with the keyboard detached and the accelerometer claimed hung the Z13. It needed a hard reset, and the next power-on froze at the ROG logo.
  - The daemon now holds a logind delay inhibitor and has a `_sleep-reader` (`gdbus monitor` on `PrepareForSleep`).
  - On `sleep pre` it stops the sensor reader and waits for the process group to exit, waits 300 ms, kills wvkbd, then releases the inhibitor.
  - On `sleep post` it takes the inhibitor again, and after `resume_delay_ms` (2 s) re-claims, restores wvkbd and re-checks the keyboard.
  - The root cause is still being isolated with `scripts/suspend-test.sh` (see `to-do.md`).
- **Never trust a pid file blindly.** Use `pid_of <file> <cmdline-fragment>`: it rejects 0 and 1 (`kill -- -1` would take down every process the user owns) and any pid whose command line no longer matches, which can happen after reuse. The daemon clears stale reader and inhibitor files at start (security review, 2026-10-05).
- **The record of the user's own option values (`tweaks.lua`) is taken once, when the tweaks first go on, and never retaken.**
  - **What went wrong:** retaking it after a config reload captured our own tweak values. Hyprland can still hold them after a reload, so every later restore put 8/14 back (seen 2026-10-06).
  - **The guard:** `tweaks_apply` won't record live values that equal the current tweak values. It falls back to `$BASELINE` (`~/.local/state/omarchy-tablet-mode/baseline.lua`, the last clean record, written on every clean record).
  - **Validation:** every record is checked by `tweaks_record_ok` (an `hl.config` of names and numbers/booleans only) before it's evaluated.
  - **Tests:** override the path with `TABLET_MODE_BASELINE`. Never move `XDG_STATE_HOME` in tests, because mise keeps its trust list there and then refuses to run `python3`.
- **The menu file is the user's.** `menu_remove` only acts on an intact block (one begin marker before one end marker), and `menu_add` never edits the user's lines: a missing comma goes inside our block as a lone `,`. Every result must pass `jsonc_ok` (string-aware) or nothing is written.
- **Package builds come from a reviewed private copy.** `build_reviewed` refuses a recipe containing anything but plain files (a symlink would be re-read after review). It copies the recipe to a `mktemp -d` folder, prints every file with `cat -v`, asks, then runs `makepkg` in that same copy. Never `--noconfirm`.
- **The hold patch has to release keys itself.** With release-on-motion gone (it was upstream's only early release), `hold-until-release.patch` also releases the held key in `wl_touch_cancel` and at the top of `hide()`, which covers SIGUSR1, rotation and resize (those go through hide/show). wvkbd doesn't handle SIGTERM, so `osk_stop` hides the keyboard first and kills it afterwards (second security review, 2026-10-05).
- **Every reader started with `start_reader X` needs an `_X-reader)` dispatch line.** One was missing once, and the dry-run tests can't see it; `test/run.sh` now checks this statically.
- **Never restart the shell in the middle of a hot-reload burst.** On 2026-10-06, deploy.sh copied files (the shell hot-reloads the plugin once per file) and restarted the shell 20 ms later. Quickshell 0.3.1 segfaulted in `__dynamic_cast` under `QQmlComponent::createObject`, run from a JS handler while the engine was exiting; the same signature is in omacom/omarchy#8647. deploy.sh now waits 3 s before `omarchy restart shell`.
- **`Widget.qml` changes need `omarchy restart shell`.** The shell doesn't reload an already-loaded bar widget when its file is replaced, so it keeps running the old code with no error. `scripts/deploy.sh` restarts the shell when `Widget.qml` changed. Quickshell's `console.log` doesn't reach the journal, but `console.warn` does.
- **Write the palette as `Commons.Color`, never bare `Color`** (`import qs.Commons as Commons`). Qt 6.12 (Omarchy 4.0.5, 2026-10-19) added a QtQuick `Color` type that shadows Omarchy's singleton. Omarchy's patched Quickshell still pins unversioned `import QtQuick` to 6.11 (omacom/omarchy#14845), but that's a stopgap; its docs require plugins to qualify (#14553). `test/run.sh` checks this statically.
- **The on-screen keyboard is `wvkbd-deskus`**, a US desktop layout built from `packaging/wvkbd-deskus`. That's upstream 0.20 (the checksum pinned to match the AUR package) plus two patches (GPL-3.0, like wvkbd; the rest of the repo is MIT):
  - `deskus-layout.patch` removes the Compose key from the home row and widens Caps and Enter to 1.75.
  - `hold-until-release.patch` (pkgrel 2) stops upstream's release-on-any-finger-motion in `kbd_motion_key`, so a held key (Voxtype's hold-to-talk F9) stays down until the finger lifts. pkgrel 3 adds releases on touch-cancel and in `hide()`. Key-down is still sent at touch-down, so typing is unchanged.

  `osk_outdated` compares the installed version with the recipe's `pkgver-pkgrel`; `install` rebuilds the keyboard when it's older, and `doctor` says so. `osk_bin` falls back to `wvkbd-mobintl`, and either one counts as set up. `tablet-mode install` builds deskus through `build_reviewed`: copy the recipe, show every file, ask, then run `makepkg` in that same copy.
- **Floating keyboard button:** a `PanelWindow` in `Widget.qml` (namespace `tablet-mode-keyboard-button`), shown only in tablet mode, and only by the bar instance on the built-in display. It uses `ExclusionMode.Normal`, so wvkbd's exclusive zone pushes it up to sit above the keyboard.
- **Docked behaviour (2026-10-06):**
  - **`desired_transform`:** in tablet mode, unlocked, it's the sensor's latest `$ORIENT`; otherwise `$TRANSFORM`. `reapply` (reload or monitor added) rotates to it, because the sensor only reports changes and the panel may have been off when the tablet turned.
  - **Desk mode:** `DESK`, through `sync_panel`, runs after every reload, monitor added and monitor removed. With the panel off it pauses wvkbd and the tweaks (global gaps would hit the external monitor) and keeps the sensor claimed. Omarchy's Laptop Display toggle works by `hyprctl reload`, so the reload path matters most.
  - **Layout guards in `rotate_to`:** `layout_blocker` (one `jq` pass over `monitors all`) blocks any rotation while mirrored, and blocks sideways transforms whose rotated logical rectangle at the same position would overlap another enabled monitor. Rotating back to 0 is always allowed. `notify_blocked` notifies once per monitor and transform per session. Never edit the user's layout.
  - **Keyboard placement:** upstream wvkbd creates its layer surface with a NULL output, so it lands on the focused monitor. It also re-creates the surface (hide/show) on every resize or rotation, so a focus trick at show time isn't enough: docked, it jumped to HDMI on the next rotation (seen 2026-10-06).
    - `stay-on-output.patch` (pkgrel 4) adds `--output NAME`. It binds wl_output v4, matches on the `name` event, uses that output for both `get_layer_surface` calls, and falls back to NULL when that global is removed (panel off).
    - `osk_start` passes `--output <panel>` when `--help` lists it and sets `OSK_PINNED`.
    - Only unpinned builds use `osk_focus_panel`/`osk_focus_back`: focus the panel, hold it until `osk_layer_monitor` shows wvkbd there (≤1.5 s, since a just-started wvkbd handles SIGUSR2 late), then focus back and restore the cursor.
  - **`unrotate`** sets `TRANSFORM=$(current_transform)`, not 0. A panel the config already rotates must not be "corrected" by the next reload.
  - **`config_notes`** (in doctor) is a comment-stripping grep heuristic over `~/.config/hypr/*.lua`. It produces notes only.
- **wvkbd never gets `--auto`.** Its input-method mode would compete with fcitx5.
- Tests must not write inside the plugin folder: the shell hot-reloads the plugin on every file change. `test/run.sh` uses `mktemp -d`.

## Test

```bash
test/run.sh                          # dry-run suite, no Hyprland changes
omarchy plugin validate .            # manifest/entry points
bin/tablet-mode doctor [--full]      # on the real machine
```

Real-hardware checks (Z13): detach/attach, all four poses with touch and pen landing correctly, `hyprctl reload` while rotated, suspend/resume, docked to HDMI (external never rotated, eDP-1 stays at `320x1080`), `disable` → `doctor`, `kill -9` the daemon while rotated, and the card at Display scale 3 and 4 (4 gives 640x400 logical; the card scrolls there). Change the scale live with `hyprctl eval` replaying mode and position, never `omarchy-hyprland-monitor-scaling` (it rewrites `monitors.lua`).
