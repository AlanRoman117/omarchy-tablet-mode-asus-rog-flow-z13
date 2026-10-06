<!--
POSTED 2026-10-05 as https://github.com/omacom/omarchy/discussions/14341
(Omarchy has blank issues disabled; its issue template sends suggestions to Discussions.)
Duplicate check (2026-10-05): no existing issue, PR or discussion about touch or on-screen input on the lock screen.
Nearby: #11224 (biometric hook), #9029 / #9756 (on-screen keyboards vs the menu and bar panels).
-->

# Lock screen: allow unlocking by touch when no keyboard is attached

**System:** ASUS ROG Flow Z13 (GZ302EA, Ryzen AI Max+ 395), Omarchy 4.0.4, Hyprland 0.56.2, kernel 7.2.5. It's a detachable: with the keyboard off, it's a touchscreen tablet.

## The problem

With the keyboard detached there's no way to unlock the lock screen. After a suspend or an idle lock, the password field is there but nothing can type into it:

- Layer-shell on-screen keyboards (wvkbd, in my case) don't show over the session lock, so there's nothing to tap.
- The Z13 has no fingerprint reader, so the fingerprint flow doesn't help either.

The only way in is to reattach the keyboard, type the password, and detach it again.

This affects any 2-in-1 or detachable used as a tablet: Surface-style devices, the Z13, convertibles folded flat, and the GPD Pocket 4 mentioned in #9029.

## Suggestion

An optional on-screen keyboard drawn by the lock screen itself (`plugins/lock/LockView.qml`). It would type into the existing password field and submit through the existing `omarchy-lock-password` PAM flow, so authentication stays exactly as it is:

- **When it appears:** only when it's needed. That could be after a touch on the lock screen, or when no physical keyboard is present (no non-virtual keyboards in `hyprctl devices`), or behind a setting.
- **Keys:** a plain QWERTY layout plus shift, symbols, backspace and enter.
- **No feedback that leaks the password:** no key-press popups or enlarged keys, so nobody watching can read it off the screen. Ideally no per-key highlight either.
- **Nothing added to authentication:** no new PAM service, no PIN, no new credential.

Because it lives inside the lock surface, it avoids the input-routing problems the menu and bar panels have with external on-screen keyboards (#9029, #9756). It also needs no third-party keyboard to be trusted with the password.

## Why not a plugin

A third-party plugin could do this by cloning `omarchy.lock`, since clones keep the `authentication` capability. But that means users run a forked lock screen that stops getting upstream fixes, which is the wrong place to fork. It seems better as an opt-in part of the stock lock.

## Context

I'm using a small personal plugin for tablet mode on the Z13 (auto-rotation, wvkbd and touch tweaks when the keyboard detaches). It deliberately leaves the lock screen alone, which is why I'm suggesting this upstream instead of working around it.

Happy to test on the Z13.
