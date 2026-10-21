# To do

## On-screen keyboard layout (raised 2026-10-05): done

- **Problem:** the AUR wvkbd's phone-style `mobintl` layouts put Tab, Enter and the arrows in unexpected places.
- **Now:** `wvkbd-deskus`, built from `packaging/wvkbd-deskus` (upstream 0.20 deskintl, with Cmp taken off the home row). A real US layout: Tab on the left, Caps then the home row then Enter, and an inverted-T of arrows bottom right.
- **Show/hide:** a floating ⌨ button in tablet mode, bottom right, that moves up above the keyboard while it's shown.
- [x] Installed wvkbd-deskus 0.20-1 on the Z13 and typed on it in tablet mode. The user says it's "much better".
- [x] Holding F9 (Voxtype) let go on the slightest finger movement, because upstream releases on any touch motion. Fixed in 0.20-2 with `hold-until-release.patch`. Installed and re-tested 2026-10-05: hold-to-dictate works even with a sliding finger.
- Possible later: a symbols-page review, and key height (6 rows in 300 px).

## Suspend hang in tablet mode (2026-10-05): open

**What happened:** with the keyboard detached and the plugin in tablet mode (accelerometer claimed, wvkbd up), `systemctl suspend` never resumed; the log ends at `PM: suspend entry (s2idle)`. It needed a hard reset. The next power-on froze at the ROG logo and needed a second hard reset, then it reset itself and booted. The same session had suspended and resumed fine 2 minutes earlier, with the keyboard attached and the plugin idle.

**Mitigation, deployed 2026-10-05:** a logind delay inhibitor and `sleep pre`/`post` handling. The accelerometer and wvkbd are released before sleep and restored after.

**Isolation** with `scripts/suspend-test.sh` (the plugin is off during these; after a hang: hard reset, then `scripts/suspend-test.sh report`):

- [x] Rehearsal: `detached-sensor --rehearse` (pm_test=devices). **Passed 2026-10-05.** All device callbacks are fine with the claim on and the keyboard off. The accelerometer is behind the **ITE8353 I2C HID sensor hub** (EC family), not amd_sfh; it resumed in about 90 ms. So a hang would be in the firmware s2idle entry or exit, which only a real suspend exercises.
- [x] A. `sensor`: keyboard on, claim on. **Resumed 2026-10-05**, so the claim alone is not the cause.
- [x] B. `detached`: keyboard off, nothing claimed. **Resumed 2026-10-05**, so a detached keyboard alone is fine.
- [x] C. `detached-sensor`: **Resumed 2026-10-05**, so the combination isn't the cause either. Left from the original hang: wvkbd on screen, the touch mapping and tweaks, or a one-off (it came 20 s after a previous resume).
- [~] D. `plugin`: resumed once (2026-10-05), and the release before sleep and the restore after were confirmed in the journal.
- **Caveat on A–D:** every real test suspend today woke by itself after about 3.4 s (IRQ 0/1/7, "Wakeup unrelated to ACPI SCI"). The 16:39 suspend before the hang lasted 104 s. Possible causes are the known GZ302 premature-wake regression on 7.1.8+ (CachyOS #972) or pm_trace's RTC writes. A–D prove entry and exit, not a long deep sleep.
- [ ] E. `plugin --no-trace`: a long sleep (about a minute) x3. This is the real verdict.
  - [x] Run 1 (2026-10-05): asleep 79.3 s, woke on the power button; released before sleep, restored after. Without pm_trace there was no early self-wake, so pm_trace was what caused the 3.4 s wakes.
  - [x] Run 2 (2026-10-05): asleep 95.5 s, released before sleep, restored to tablet mode after (keyboard still off).
  - [ ] Run 3
- [ ] Optional: `detached-osk` (plugin off, wvkbd shown, keyboard off) to prove or clear wvkbd as the cause.

## Unlocking in tablet mode: decided 2026-10-05, out of scope

The lock screen (ext-session-lock) covers wvkbd, so you can't type the password with the keyboard detached; reattach it to unlock.

The user declined the alternatives:
- **Face unlock** (Howdy).
- **A cloned lock screen with a touch keyboard.** Technically possible, since clones inherit `authentication` through `omarchy.clonedFrom`. Rejected because the plugin must not take on authentication code or drift from upstream lock fixes.
- **Not locking in tablet mode.**

The limitation is documented in the README. Posted 2026-10-05 as omacom/omarchy discussion #14341 (https://github.com/omacom/omarchy/discussions/14341); the text is in `docs/upstream/lock-screen-touch-input.md`. Watch it for replies.

## Docked tablet mode (2026-10-06): done

- [x] Docked, keyboard off, laptop screen off: no keyboard on HDMI, and `tablet-mode status` says desk (user, 2026-10-06).
- [x] Found while checking that: the gaps were stuck at the tweak values (8/14). The record of the originals had been retaken after a reload that left our tweaks in place. Fixed: the record is never retaken, there's a guard and a baseline, and records are validated. The user's values were reset to 5/10 by hand.
- [x] Hold the tablet sideways, then turn the laptop screen on: portrait about 0.1 s after the screen comes up (a brief landscape flash, since Hyprland enables it per monitors.lua first). The log shows `panel back: transform 1`, and the keyboard is on the laptop screen (user, 2026-10-06).
- [x] The keyboard stays on the laptop screen while HDMI has focus, including through a rotation (wvkbd-deskus 0.20-4 with `--output`, 2026-10-06).
- Note (2026-10-06): a Quickshell crash during a dev deploy was the shell restart racing the plugin hot-reload burst (an upstream Quickshell bug, also in omacom/omarchy#8647). deploy.sh now waits before restarting. No user data was involved.
- [x] Laptop screen off again: desk mode; gaps back to 5/10 and to 8/14 when it's on (checked from the log and getoption, 2026-10-06).
- [x] Reattach the keyboard: laptop mode, landscape, gaps 5/10, no live-change records left, layout unchanged (user + checked, 2026-10-06).
- [x] `tablet-mode doctor`: "can turn sideways without overlapping", no config notes (docked, 2026-10-20).

## Hardware checks still to run (Z13)

- [x] Detach / attach, notifications, the keyboard appearing, all four poses, touch and pen (2026-10-05). Default mapping is correct; no calibration needed.
- [ ] `hyprctl reload` while rotated keeps the rotation.
- [ ] Suspend and resume in tablet mode (see the open issue above); a reboot with the keyboard detached.
- [x] Docked to HDMI: the external monitor is never rotated, and eDP-1 stays at `320x1080` after reattaching (checked through the 2026-10-20 rotation tests and the user's detach/attach).
- [x] `disable` while rotated → landscape, and `doctor` passes every plain-Omarchy check; `enable` brings it all back (2026-10-20). `disable --full` then `enable` removed and restored the entries and bar icon (user, 2026-10-19). Not run: `doctor --full` after `disable --full` (re-enabling moves the bar icon back to its default section).
- [x] `kill -9` the daemon while rotated → landscape again within 1.5 s, records cleared, the service restarted after 3 s (2026-10-20).

## Pre-submission review of v0.1.0 (2026-10-20): fixed, released in v0.1.1

A subagent's read-only review of the release and `develop` found no Critical or High issues. The root boundary, injection, process control, the lock screen and the C patches hold. Submission was blocked by a private repo (the user's to change) and by M1. 16 new tests (161 passing); the 11 behaviour tests fail against `develop`.
- **M1 (functional):** on any machine that isn't a Z13, the default keyboard id read as detached, so tablet mode came on at `enable` and at every login. Now an id never present on the machine is `unknown`. The README tells non-Z13 users to set theirs before finishing setup.
- **L1:** every touchscreen was mapped to the panel, external touch monitors included. Now only the single built-in one (`auto`), or those named in `touch_devices=`.
- **L2:** the reviewer thought rotation might drop live-set bitdepth/cm/vrr. Measured on the Z13: it doesn't. `hl.monitor` merges with the live rule, so 10-bit set live survived two plugin rotations. Nothing to fix; a doctor note and README line added for it were taken out again.
- **I1:** the reviewer said `KillMode=mixed` SIGKILLs leftovers before `ExecStopPost`. Measured with transient units: not on a requested stop, but yes when the daemon itself dies (crash, `kill -9`). Then `restore` still un-rotates (checked on the Z13), but a key held at that instant isn't released. The unit comment says so.
- **I2:** wvkbd's close handler left dangling surface pointers and never released a held key. Fixed in wvkbd-deskus 0.20-7.
- **I3–I6:** menu entries call the plugin's own script; `uninstall --packages` removes only `wvkbd-deskus`; deploy keeps `.git`; Omarchy's files always come from `~/.config/omarchy`.
- **Submission items:** the README lists the tools it uses, the sentence the scanner read as running sudo is reworded, and the merged branch is deleted from GitHub.
- [x] Installed 0.20-7; the on-screen keyboard works, holding F9 included (user, 2026-10-20).
- [x] `doctor` recorded the Z13 keyboard as seen; detaching it still enters tablet mode (user, 2026-10-20).
- [x] L2 checked live: a live 10-bit setting survived `rotate 90` and `rotate normal`. The panel was put back exactly (8-bit, VRR off, unlocked).
- [x] v0.1.1 released and the repo made public (2026-10-20).
- [ ] Release v0.1.2 (marketplace preview image, listing name "Tablet Mode (ROG Flow Z13)"), then submit to the marketplace (the draft passed its validator; the security baseline is `review-required` with no findings).

## Third security review, pre-release (2026-10-19): fixed and verified on the Z13, released in v0.1.0

A subagent's read-only review of the whole repo found no Critical, High or Medium issues. The root boundary, Lua injection, process control and the lock screen all hold. Every finding is fixed on `security-review-fixes` (off `develop`), with 19 new tests (144 passing). The 13 behaviour tests fail against the old code.
- **Low:**
  - `jsonc_ok` imported modules from the current folder (`python3 -I` now);
  - `menu_remove` could leave the menu unparseable (now checked, keeping a needed comma);
  - a symlinked menu was replaced by a file and its backup was a link;
  - the service's stop SIGTERM killed wvkbd before it could hide (`KillMode=mixed`).
- **Info:**
  - an empty `cmd` event killed the daemon;
  - `08` in the config was read as bad octal;
  - `tweaks_record_ok` let Lua `f{...}` calls through;
  - the recipe's plain-file check ran on the source, not the copy, `--yes` skipped the build question, and Ctrl-C left the build folder;
  - `uninstall` ran `rm -rf` on override paths;
  - deploy's unit write, and the widget's `/tmp` fallback;
  - a flaky `grep -q` under `pipefail`.
- **Release hygiene:**
  - the patch count, licences (`GPL-3.0-only MIT`, upstream's licence files installed, SPDX headers on the patches; wvkbd-deskus 0.20-5);
  - README links to dev files;
  - `scripts/release.sh`, so `main` ships only runtime files.
- [x] Rebuilt the keyboard (0.20-5) and ran the tablet-mode checks: all passed (user, 2026-10-19).
- [x] `systemctl --user restart omarchy-tablet-mode` while holding F9: nothing stuck, but wvkbd segfaulted. The hold patch's release in `hide()` queued a frame callback on the key popup, which `hide()` then destroyed. Fixed in 0.20-6 (see CLAUDE.md).
- [x] Installed 0.20-6 through `tablet-mode install -y` (the reviewed build flow; its build question cannot be skipped), then repeated the held-F9 restart and a rotation while holding a key: no crash, nothing stuck (user, 2026-10-19).

## Second security review (2026-10-05): fixed

No high findings, and the auth boundary is intact.
- **Medium:** the hold patch could leave keys stuck. Fixed in wvkbd-deskus 0.20-3: release on touch-cancel and in `hide()`, and `osk_stop` hides before it kills. Installed, and hold-to-dictate re-tested OK by the user.
- **Low:**
  - the recipe review could be fooled by symlinks (now plain files only, shown with `cat -v`);
  - the delay lock was taken without the sleep listener (now only when it runs);
  - documentation accuracy;
  - licensing: the patches are GPL-3.0-only, the rest MIT, and the README says so.
- **Info:**
  - test timing loosened;
  - `set_config` follows symlinks.

## Security review (2026-10-05): fixed

A subagent read-only review found no high or medium issues, and the auth boundary is untouched. The six low findings are all fixed and covered by tests (92 passing):
- the snapshot was retaken on a panel re-add;
- calibrate left the service stopped;
- `menu_remove` could delete to the end of the menu file;
- pid files were trusted, including `1` and reused pids;
- the AUR review was cosmetic; it's now a reviewed checkout built with makepkg;
- `/tmp` race in the tests.

Minor items fixed too: no glob expansion of commands, the sleep signal is matched on logind's name, unusual install paths are refused, uninstall removes the menu backup, and the suspend-test status write is safe.

## Later

- Watch omacom/omarchy discussion #14341 (touch input on the lock screen); no replies as of 2026-10-20.
- Public since 2026-10-20. The commit author email (alan.roman117@gmail.com) is fine to publish (the user confirmed 2026-10-05). This file and CLAUDE.md stay on `develop` and never ship (`release.sh`).
- Touch gestures (hyprgrass), as a possible v2.
