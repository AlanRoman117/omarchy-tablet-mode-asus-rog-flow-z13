# To do

## On-screen keyboard layout (raised 2026-10-05)

The user finds the current layout awkward to type on: key spacing and placement don't feel like a standard keyboard. Not a blocker.

- The AUR package only builds `wvkbd-mobintl`, a phone-style layout with offset rows, no number row on the main layer, and Cmp/Ctr keys.
- Options to look at:
  - wvkbd's `deskintl` layout. It's built with `make LAYOUT=deskintl` and gives a desktop-style layout with a number row. It would need its own build or package, or an AUR `-git` variant.
  - Choosing layers with `-l` / `--landscape-layers` (`wvkbd-mobintl --list-layers`).
  - Font size (`--fn`), height (`osk_height_*`) and turning off key-press popups (`--no-popup`).
  - Alternatives if wvkbd can't be made comfortable. squeekboard has a fuller layout but replaces fcitx5 as the input method.
- Decide together with the user. Show screenshots of the candidates first.

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

## Hardware checks still to run (Z13)

- [x] Detach / attach, notifications, the keyboard appearing, all four poses, touch and pen (2026-10-05). Default mapping is correct; no calibration needed.
- [ ] `hyprctl reload` while rotated keeps the rotation.
- [ ] Suspend and resume in tablet mode (see the open issue above); a reboot with the keyboard detached.
- [ ] Docked to HDMI: the external monitor is never rotated, and eDP-1 stays at `320x1080` after reattaching.
- [ ] `tablet-mode disable` while rotated → `doctor` passes; `disable --full` → `doctor --full`; `enable` brings everything back.
- [ ] `kill -9` the daemon while rotated → `ExecStopPost` restores landscape.

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

- A private GitHub repo `AlanRoman117/omarchy-tablet-mode-asus-rog-flow-z13`, once the checks above pass. Ask first.
- Touch gestures (hyprgrass), as a possible v2.
