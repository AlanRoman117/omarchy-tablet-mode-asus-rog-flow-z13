# Tablet Mode for Omarchy

Take the keyboard off a detachable and Omarchy turns into a tablet. The screen follows the accelerometer, an on-screen keyboard appears, and window gaps and border grab areas get bigger for fingers. Put the keyboard back and it's a laptop again. One switch turns the whole plugin off and returns the system to plain Omarchy.

**Tested so far on one machine only: ASUS ROG Flow Z13 (GZ302EA), Omarchy 4.0.4, Hyprland 0.56.2.** Other detachables and convertibles should work after setting their keyboard's USB id and running `calibrate`.

## What it does

| | Keyboard detached (or toggled on) | Keyboard attached (or toggled off) |
|---|---|---|
| Rotation | Follows the accelerometer, touchscreen and pen included | Landscape |
| On-screen keyboard | Shown ([wvkbd](https://git.sr.ht/~proycon/wvkbd), themed to match) | Hidden |
| Touch tweaks | Wider gaps; borders easier to grab | Hyprland's own values back |
| Notification | "Tablet mode" | "Laptop mode" |

External monitors are never rotated. Your `monitors.lua` is never edited: every change is applied live, re-applied after a config reload, and undone when the plugin stops.

## Requirements

- Omarchy 4 (Hyprland with Lua config).
- An accelerometer that iio-sensor-proxy can read (`ls /sys/bus/iio/devices/*/in_accel_x_raw`).
- For automatic tablet mode, a keyboard that appears and disappears as a USB device. The Z13's is `0b05:1a30`.

## Install

The plugin isn't published yet. For now it's installed as a local folder at `~/.config/omarchy/plugins/alanroman117.tablet-mode/`.

Then click the dimmed laptop icon in the bar. The card walks you through setup:

1. **Set up** opens a terminal and asks for your password. It installs `iio-sensor-proxy` from the Arch repos. Then it downloads wvkbd's AUR build recipe, shows you the whole PKGBUILD, and asks before building. What you read is exactly what gets built, and makepkg checks the upstream source's checksum.
2. **Finish setup** starts the service, adds the menu entries and installs a theme hook.
3. **Calibrate** once (on the card, or `tablet-mode calibrate`). It needs two poses, and you confirm the picture is the right way up.

Omarchy's plugin installer never runs code or sudo, which is why setup is a step you start yourself. From a terminal, the same steps are `tablet-mode install`, `tablet-mode enable` and `tablet-mode calibrate`. After `enable`, `tablet-mode` is on your PATH through `~/.local/bin`.

## The card

Tap the bar icon:

- **Tablet mode**, **On-screen keyboard** and **Rotation lock** switches.
- **Turn the screen**: 0°, 90°, 180° or 270°. Picking one locks rotation.
- **Calibrate**, **Check** (runs `doctor`) and **Turn off**.

The same switches are in the Omarchy menu under **Trigger → Toggle**.

## Commands

```bash
tablet-mode status            # what's going on (--json for scripts)
tablet-mode on|off|toggle     # by hand, until the keyboard is next attached or detached
tablet-mode rotate 90         # normal|90|180|270, and locks rotation
tablet-mode lock toggle       # rotation lock
tablet-mode osk toggle        # on-screen keyboard: show|hide|toggle
tablet-mode doctor            # check the setup
```

## Turning it off: plain Omarchy

```bash
tablet-mode disable           # everything off, every change undone, nothing starts at login
tablet-mode disable --full    # also removes the menu entries, the theme hook and the bar icon
tablet-mode doctor --full     # proves it: no processes, no rotation, no tweaks, no entries
tablet-mode enable            # all back
```

`disable` keeps the bar icon, dimmed, with a **Turn on** button. A menu entry (**Tablet Mode Plugin**) does the same. Packages stay installed and idle: iio-sensor-proxy only starts when something asks for the accelerometer, and wvkbd doesn't run. `tablet-mode uninstall --packages` removes them too.

If the service crashes or is killed, its `ExecStopPost` runs `tablet-mode restore`. The screen is never left rotated or the keyboard left up.

## Settings

`~/.config/omarchy/tablet-mode.conf`, written by `enable`:

| Key | Default | |
|---|---|---|
| `keyboard` | `0b05:1a30` | USB `vendor:product` of the detachable keyboard (`lsusb`); `none` = toggle only |
| `output` | `auto` | Built-in display (first `eDP`/`LVDS`/`DSI`) |
| `auto_rotate`, `show_keyboard`, `touch_tweaks`, `notify` | `true` | What tablet mode does |
| `orientation_offset`, `orientation_mirror` | `0`, `false` | Set by `calibrate` |
| `debounce_ms` | `400` | How long an orientation must hold before the screen turns |
| `gaps_in`, `gaps_out`, `border_grab` | `8`, `14`, `30` | Touch tweaks, in pixels |
| `osk_height_landscape`, `osk_height_portrait` | `300`, `420` | On-screen keyboard height |

After editing, run `systemctl --user restart omarchy-tablet-mode`.

## Limitations

- **Unlocking needs the keyboard.** Omarchy's lock screen (shown after suspend or idle) covers everything, including the on-screen keyboard. With the keyboard detached there's no way to type your password: reattach it to unlock, then detach again. This is deliberate. The plugin stays out of authentication: it doesn't modify or replace the lock screen, so it adds nothing to what someone holding your tablet could get past. Touch input on the lock screen belongs in Omarchy itself.

## Good to know

- **The on-screen keyboard doesn't pop up when you tap a text field.** That would need wvkbd's input-method mode, which competes with fcitx5 (Omarchy's input method). It appears in tablet mode, and the card, the menu and `tablet-mode osk toggle` show or hide it.
- **Typing on it into the Omarchy menu or a bar popup closes them.** This is an Omarchy bug, tracked in [omacom/omarchy#9029](https://github.com/omacom/omarchy/issues/9029) and [#9756](https://github.com/omacom/omarchy/issues/9756). Normal app windows are fine.
- **Suspend:** before every sleep the service lets go of the accelerometer and closes the on-screen keyboard, using a logind delay lock, and brings them back about 2 seconds after resume. An early version without this hung the Z13 once when suspending in tablet mode. With it, tablet-mode suspends of 80-95 seconds resumed cleanly (see `to-do.md`).
- The accelerometer is only claimed while auto-rotation is active (tablet mode, unlocked), so it isn't kept powered in laptop mode.
- The rotation lock carries over between modes, as on a phone.

## How it works

`bin/tablet-mode daemon` runs as the `omarchy-tablet-mode` user service. It handles one event at a time from a FIFO, fed by three readers:

- `monitor-sensor` for orientation;
- `udevadm monitor` for USB add and remove;
- Hyprland's event socket for config reloads and monitors being added.

Rotations replay the panel's live mode, position and scale with the new transform (a transform-only rule resets the scale), and set each touch and pen device's transform explicitly. State goes to `$XDG_RUNTIME_DIR/omarchy-tablet-mode/state.json`, which the card watches.

## Uninstall

```bash
tablet-mode uninstall [--packages]
omarchy plugin remove alanroman117.tablet-mode
```

## Licence

MIT.
