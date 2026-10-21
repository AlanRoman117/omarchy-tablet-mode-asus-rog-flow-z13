#!/bin/bash

# Dry-run tests: the daemon runs without readers against fake hyprctl output
# (test/fixtures) and logs what it would do instead of doing it.
#
# Usage: test/run.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/../bin/tablet-mode"
TMP=""
PASS=0
FAIL=0

# A fresh private directory per scenario: never reuse a name another user could
# recreate between a delete and a mkdir.
setup() {
  [[ -n $TMP ]] && rm -rf "$TMP"
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/tablet-mode-test.XXXXXX")" || exit 1
  mkdir -p "$TMP/run" "$TMP/fixtures" "$TMP/config/omarchy/extensions"
  cp "$HERE"/fixtures/* "$TMP/fixtures/"
  echo attached >"$TMP/fixtures/keyboard"
  cat >"$TMP/tablet-mode.conf" <<EOF
enabled=true
debounce_ms=100
resume_delay_ms=200
${1:-}
EOF
  : >"$TMP/log"
  export TABLET_MODE_DRYRUN=1 TABLET_MODE_FIXTURES="$TMP/fixtures" TABLET_MODE_RUN_DIR="$TMP/run"
  export TABLET_MODE_CONF="$TMP/tablet-mode.conf" TABLET_MODE_LOG="$TMP/log" XDG_CONFIG_HOME="$TMP/config"
  export TABLET_MODE_BASELINE="$TMP/state/omarchy-tablet-mode/baseline.lua"
  # Omarchy's menu, hooks and shell.json live in ~/.config/omarchy whatever XDG_CONFIG_HOME says.
  export TABLET_MODE_OMARCHY_CONFIG="$TMP/config/omarchy"
}

start() {
  "$CLI" daemon --no-readers 2>>"$TMP/stderr" &
  DPID=$!
  for _ in $(seq 50); do [[ -p $TMP/run/events && -f $TMP/run/state.json ]] && return 0; sleep 0.05; done
  echo "daemon didn't start"; cat "$TMP/stderr"; exit 1
}

stop() {
  kill "$DPID" 2>/dev/null
  wait "$DPID" 2>/dev/null
}

event() { "$CLI" send "$@" && sleep "${WAIT:-0.6}"; }
mark() { : >"$TMP/log"; }

pass() { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; sed 's/^/      | /' "$TMP/log"; }

has() { if grep -qF -- "$2" "$TMP/log"; then pass "$1"; else fail "$1 (expected: $2)"; fi; }
lacks() { if grep -qF -- "$2" "$TMP/log"; then fail "$1 (unexpected: $2)"; else pass "$1"; fi; }
state() { jq -r "$1" "$TMP/run/state.json" 2>/dev/null; }
is() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

echo "Daemon: keyboard detach, rotation, lock, reload, attach"
setup
start
is "starts in laptop mode with the keyboard attached" "$(state .mode)" laptop
lacks "touches nothing at start" "eval"

echo detached >"$TMP/fixtures/keyboard"
WAIT=1.6 event usb
is "detaching the keyboard enters tablet mode" "$(state .mode)" tablet
is "source is the keyboard" "$(state .source)" keyboard
has "shows the on-screen keyboard" "osk show"
has "applies touch tweaks" "eval hl.config({ general = { gaps_in = 8, gaps_out = 14, extend_border_grab_area = 30, resize_on_border = true }, cursor = { hide_on_touch = true } })"
has "claims the accelerometer" "reader start sensor"
has "notifies" "notify Tablet mode: Keyboard shown · touch tweaks on · auto-rotation on"

mark
event "orient left-up"
has "rotates the panel with its live mode, position and scale" 'eval hl.monitor({ output = "eDP-1", mode = "2560x1600@180.00000", position = "0x0", scale = 1.6, transform = 1 })'
has "rotates the touchscreen" 'eval hl.device({ name = "elan9008:00-04f3:43c7", transform = 1, output = "eDP-1" })'
has "rotates the pen" 'eval hl.device({ name = "elan9008:00-04f3:43c7-stylus", transform = 1, output = "eDP-1" })'
lacks "leaves other tablets alone" "wacom-pen"
lacks "never touches the external monitor" "HDMI-A-1"
is "state records the transform" "$(state .transform)" 1

mark
"$CLI" send "orient bottom-up"
event "orient left-up"
lacks "debounces a wobble back to the same orientation" "transform = 2"

mark
event "cmd lock on"
has "lock releases the accelerometer" "reader stop sensor"
event "orient right-up"
lacks "locked: ignores the sensor" "transform = 3"
is "state shows the lock" "$(state .lock)" true
mark
event "cmd lock off"
has "unlock claims the accelerometer again" "reader start sensor"
event "orient left-up" # a fresh claim reports the current orientation

mark
echo 0 >"$TMP/run/fake-transform" # what a config reload does to the panel
event "hypr reload"
has "re-applies the rotation after a reload" "transform = 1 })"
has "re-applies the touch tweaks after a reload" "gaps_in = 8"
[[ -f $TMP/run/rotated ]] && pass "a reload keeps the record of the original rotation" || fail "reload lost the original rotation"

mark
echo 'SNAPSHOT-SENTINEL' >"$TMP/run/tweaks.lua"
echo 0 >"$TMP/run/fake-transform" # the re-added panel lost its transform
event "hypr monitor eDP-1"
has "re-adding the panel re-applies the rotation" "transform = 1 })"
grep -q SNAPSHOT-SENTINEL "$TMP/run/tweaks.lua" && pass "re-adding the panel keeps the original settings snapshot" || fail "panel re-add retook the snapshot (would restore tablet values)"
mark
event "hypr monitor HDMI-A-1"
lacks "an external monitor being added changes nothing" "eval"
event "hypr reload"
grep -q SNAPSHOT-SENTINEL "$TMP/run/tweaks.lua" && pass "a reload keeps the original record too" || fail "a reload retook the record (it could capture the tweaks)"
echo "hl.config({ general = { gaps_in = { top = 5, right = 5, bottom = 5, left = 5 }, gaps_out = { top = 10, right = 10, bottom = 10, left = 10 }, extend_border_grab_area = 15, resize_on_border = false }, cursor = { hide_on_touch = true } })" >"$TMP/run/tweaks.lua"

"$CLI" send cmd && sleep 0.3
kill -0 "$DPID" 2>/dev/null && pass "an empty command is ignored (the daemon keeps running)" || { fail "an empty command killed the daemon"; start; }

mark
event "cmd rotate 2"
has "manual rotate turns the screen" "transform = 2 })"
is "manual rotate locks rotation" "$(state .lock)" true

mark
event "cmd lock off"
event "sleep pre"
is "asleep in the state file" "$(state .asleep)" true
has "sleep releases the accelerometer" "reader stop sensor"
has "sleep closes the on-screen keyboard" "osk stop"
has "sleep releases the delay lock" "inhibit release"
first_stop=$(grep -n "reader stop sensor" "$TMP/log" | head -1 | cut -d: -f1)
release=$(grep -n "inhibit release" "$TMP/log" | head -1 | cut -d: -f1)
((first_stop < release)) && pass "the accelerometer is released before the lock" || fail "lock released before the accelerometer"
mark
event "orient bottom-up"
lacks "asleep: ignores the sensor" "transform = 2"
WAIT=0.9 event "sleep post"
has "resume takes the delay lock again" "inhibit take"
has "resume claims the accelerometer again" "reader start sensor"
has "resume brings the keyboard back" "osk show"
is "awake in the state file" "$(state .asleep)" false

mark
echo attached >"$TMP/fixtures/keyboard"
WAIT=1.6 event usb
is "attaching the keyboard enters laptop mode" "$(state .mode)" laptop
has "back to the original transform" "transform = 0 })"
has "touch mapping undone" 'eval hl.device({ name = "elan9008:00-04f3:43c7", transform = 0, output = "" })'
has "keyboard hidden" "osk hide"
has "Hyprland's own option values put back" "eval hl.config({ general = { gaps_in = { top = 5, right = 5, bottom = 5, left = 5 }, gaps_out = { top = 10, right = 10, bottom = 10, left = 10 }, extend_border_grab_area = 15, resize_on_border = false }, cursor = { hide_on_touch = true } })"
has "notifies" "notify Laptop mode: Landscape · keyboard hidden"
[[ ! -e $TMP/run/rotated && ! -e $TMP/run/touch-mapped && ! -e $TMP/run/tweaks.lua ]] && pass "no live changes left recorded" || fail "live-change markers left behind"

mark
event "sleep pre"
lacks "laptop mode: nothing to release but the lock" "reader stop sensor"
has "laptop mode: still releases the lock" "inhibit release"
WAIT=0.9 event "sleep post"
lacks "laptop mode: no claim after resume" "reader start sensor"
lacks "laptop mode: no keyboard after resume" "osk show"

mark
event "cmd lock on"
event "cmd toggle"
is "manual toggle enters tablet mode" "$(state .mode)" tablet
is "source is manual" "$(state .source)" manual
is "the rotation lock carries over between modes" "$(state .lock)" true
event "cmd lock off"
event "orient right-up"
stop
has "stopping the daemon closes the keyboard" "osk stop"
has "stopping the daemon un-rotates" "transform = 0 })"
[[ ! -e $TMP/run/state.json && ! -e $TMP/run/events && ! -e $TMP/run/rotated ]] && pass "stopping leaves nothing behind" || fail "files left after stop"
mark
"$CLI" restore --quiet && "$CLI" restore --quiet
lacks "restore is idempotent and touches nothing when clean" "eval"

echo
echo "Startup with the keyboard detached; detection off; disabled"
setup
echo detached >"$TMP/fixtures/keyboard"
start
is "starts in tablet mode when the keyboard is off" "$(state .mode)" tablet
stop
setup "enabled=false"
"$CLI" daemon --no-readers 2>/dev/null
is "disabled: the daemon exits at once" "$?" 0
[[ ! -e $TMP/run/events ]] && pass "disabled: nothing created" || fail "disabled daemon left files"
"$CLI" on 2>/dev/null && fail "disabled: on refuses" || pass "disabled: on refuses"
setup
echo unknown >"$TMP/fixtures/keyboard"
start
is "keyboard unknown (never seen here): starts in laptop mode" "$(state .mode)" laptop
stop

echo
echo "Keyboard detection (a machine that isn't a Z13)"
setup
source "$CLI"
load_config
FIXTURES="" USB_DEVICES="$TMP/usb"
usb() { mkdir -p "$TMP/usb/$1" && echo "$2" >"$TMP/usb/$1/idVendor" && echo "$3" >"$TMP/usb/$1/idProduct"; }
usb 1-1 1234 abcd
is "the default id, never present here: unknown, not detached" "$(keyboard_state)" unknown
[[ ! -e $KBD_SEEN ]] && pass "an absent id isn't recorded as seen" || fail "an absent id was recorded"
usb 1-2 0b05 1a30
is "the keyboard present: attached" "$(keyboard_state)" attached
grep -qx 0b05:1a30 "$KBD_SEEN" && pass "and recorded as seen on this machine" || fail "an attached keyboard wasn't recorded"
rm -rf "$TMP/usb/1-2"
is "seen before, now gone: detached" "$(keyboard_state)" detached
CFG[keyboard]=none
is "keyboard=none: unknown (toggle only)" "$(keyboard_state)" unknown

echo
echo "Docked: desk mode, the laptop screen coming back, keyboard placement"
setup
fixture() { jq "$1" "$TMP/fixtures/monitors.json" >"$TMP/m.json" && mv "$TMP/m.json" "$TMP/fixtures/monitors.json"; }
fixture 'map(.focused = (.name == "HDMI-A-1"))'
touch "$TMP/run/fake-panel-off"
echo detached >"$TMP/fixtures/keyboard"
start
is "keyboard off with the laptop screen off: desk mode" "$(state .desk)" true
lacks "desk mode: no on-screen keyboard" "osk show"
lacks "desk mode: no touch tweaks" "gaps_in = 8"
has "the notification says why" "laptop screen is off"
has "auto-rotation stays armed" "reader start sensor"
mark
event "orient left-up"
lacks "laptop screen off: nothing to turn" "hl.monitor"
mark
rm "$TMP/run/fake-panel-off"
event "hypr reload" # Omarchy's Laptop Display toggle reloads the config
has "the laptop screen comes back the way the tablet is held" "transform = 1 })"
has "touch tweaks resume" "gaps_in = 8"
has "the keyboard is placed on the laptop screen" 'hl.dsp.focus({ monitor = "eDP-1" })'
has "then focus goes back to the HDMI screen" 'hl.dsp.focus({ monitor = "HDMI-A-1" })'
is "out of desk mode" "$(state .desk)" false
mark
touch "$TMP/run/fake-panel-off"
event "hypr removed eDP-1"
is "laptop screen off again: desk mode" "$(state .desk)" true
has "the keyboard goes away" "osk hide"
has "the tweaks go away" "gaps_in = { top = 5"
mark
event "cmd lock on"
event "orient right-up"
echo 0 >"$TMP/run/fake-transform" # what the config reload does to the panel
rm "$TMP/run/fake-panel-off"
event "hypr reload"
has "locked: the screen comes back at the locked rotation" "transform = 1 })"
lacks "locked: the sensor is ignored" "transform = 3 })"
stop

echo
echo "Layout guards"
setup
fixture 'map(if .name == "HDMI-A-1" then .y = 1000 else . end)' # directly below the laptop screen
echo detached >"$TMP/fixtures/keyboard"
start
mark
event "orient left-up"
lacks "a monitor below: sideways is skipped" "transform = 1 })"
has "the notification names the monitor" "would overlap HDMI-A-1"
mark
event "orient bottom-up"
has "upside down never overlaps, so it's allowed" "transform = 2 })"
stop
setup
fixture 'map(if (.name | test("^eDP")) then .mirrorOf = "HDMI-A-1" else . end)'
echo detached >"$TMP/fixtures/keyboard"
start
mark
event "orient left-up"
lacks "mirrored: not rotated" "hl.monitor"
has "mirrored: the notification says why" "mirrored"
stop
setup
source "$CLI"
load_config
is "the real layout (HDMI above the laptop screen): no overlap" "$(layout_blocker eDP-1 1)" ""
mkdir -p "$TMP/config/hypr"
printf -- '-- hl.monitor({ output = "eDP-1", transform = 1 })\nhl.monitor({ output = "HDMI-A-1", scale = 1 })\n' >"$TMP/config/hypr/monitors.lua"
CONFIG_HOME="$TMP/config"
[[ -z $(config_notes eDP-1) ]] && pass "commented-out transforms are ignored" || fail "a commented transform was reported"
printf 'hl.monitor({ output = "eDP-1", mode = "preferred", transform = 3 })\n' >>"$TMP/config/hypr/monitors.lua"
grep -q "rotates the laptop screen" <<<"$(config_notes eDP-1)" && pass "a configured panel transform is noted" || fail "a configured transform was missed"
printf 'hl.device({ name = "elan9008:00-04f3:43c7", transform = 1 })\n' >"$TMP/config/hypr/input.lua"
grep -q "sets transform/output for elan9008:00-04f3:43c7" <<<"$(config_notes eDP-1)" && pass "a touch device rule is noted" || fail "a touch device rule was missed"

echo
echo "Original settings record"
setup
echo detached >"$TMP/fixtures/keyboard"
start
[[ -f $TMP/state/omarchy-tablet-mode/baseline.lua ]] && grep -q "gaps_in = { top = 5" "$TMP/state/omarchy-tablet-mode/baseline.lua" &&
  pass "a clean record is also kept as the baseline" || fail "no baseline written from a clean record"
stop
setup
echo detached >"$TMP/fixtures/keyboard"
# Hyprland still holds our tweaks (left behind by a reload or a crash)...
echo '{"option": "general:gaps_in", "css": "8 8 8 8", "set": true }' >"$TMP/fixtures/option-general_gaps_in.json"
echo '{"option": "general:gaps_out", "css": "14 14 14 14", "set": true }' >"$TMP/fixtures/option-general_gaps_out.json"
echo '{"option": "general:extend_border_grab_area", "int": 30, "set": true }' >"$TMP/fixtures/option-general_extend_border_grab_area.json"
echo '{"option": "general:resize_on_border", "bool": true, "set": true }' >"$TMP/fixtures/option-general_resize_on_border.json"
# ...and an earlier clean record exists.
mkdir -p "$TMP/state/omarchy-tablet-mode"
echo "hl.config({ general = { gaps_in = { top = 5, right = 5, bottom = 5, left = 5 }, gaps_out = { top = 10, right = 10, bottom = 10, left = 10 }, extend_border_grab_area = 15, resize_on_border = false }, cursor = { hide_on_touch = true } })" >"$TMP/state/omarchy-tablet-mode/baseline.lua"
start
grep -q "gaps_in = { top = 5" "$TMP/run/tweaks.lua" && pass "tweaked live values are never recorded as the originals" || fail "recorded the tweak values as the originals"
grep -q "gaps_in = { top = 8" "$TMP/state/omarchy-tablet-mode/baseline.lua" && fail "the baseline was overwritten with tweaks" || pass "the baseline isn't overwritten with tweaks"
mark
stop
has "restore puts back the real originals" "gaps_in = { top = 5, right = 5, bottom = 5, left = 5 }"
setup
source "$CLI"
echo 'hl.config({ general = { x = os.execute("touch /tmp/pwned") } })' >"$TMP/bad.lua"
tweaks_record_ok "$TMP/bad.lua" && fail "a record with code in it is refused" || pass "a record with code in it is refused"
echo 'hl.config({ general = { gaps_in = hl.config{ cursor = { x = 1 } }, x = os.exit{} }, cursor = { hide_on_touch = true } })' >"$TMP/bad.lua"
tweaks_record_ok "$TMP/bad.lua" && fail "Lua's f{...} call syntax is refused" || pass "Lua's f{...} call syntax is refused"
echo 'hl.config({ general = { gaps_in = 1 .. 2 }, cursor = { hide_on_touch = true } })' >"$TMP/bad.lua"
tweaks_record_ok "$TMP/bad.lua" && fail "concatenation is refused" || pass "concatenation is refused"
echo "hl.config({ general = { gaps_in = { top = 5, right = 5, bottom = 5, left = 5 }, gaps_out = { top = 10, right = 10, bottom = 10, left = 10 }, extend_border_grab_area = 15, resize_on_border = false }, cursor = { hide_on_touch = true } })" >"$TMP/good.lua"
tweaks_record_ok "$TMP/good.lua" && pass "a genuine record is accepted" || fail "a genuine record was refused"

echo
echo "Touchscreens"
setup
source "$CLI"
load_config
is "one touchscreen: it and its pen, not other tablets" "$(touch_devices | xargs)" "elan9008:00-04f3:43c7 elan9008:00-04f3:43c7-stylus"
jq '.touch += [{"name": "ext-touch-monitor"}]' "$TMP/fixtures/devices.json" >"$TMP/d.json" && mv "$TMP/d.json" "$TMP/fixtures/devices.json"
is "several touchscreens, auto: none (it can't tell which is built in)" "$(touch_devices | xargs)" ""
CFG[touch_devices]=elan9008:00-04f3:43c7
is "touch_devices names the built-in one: it and its pen" "$(touch_devices | xargs)" "elan9008:00-04f3:43c7 elan9008:00-04f3:43c7-stylus"
CFG[touch_devices]='nope,"x'
is "a name that matches nothing: none" "$(touch_devices | xargs)" ""

echo
echo "Orientation mapping"
setup
# shellcheck source=../bin/tablet-mode
source "$CLI"
load_config
is "normal -> 0" "$(transform_for normal)" 0
is "left-up -> 1" "$(transform_for left-up)" 1
is "bottom-up -> 2" "$(transform_for bottom-up)" 2
is "right-up -> 3" "$(transform_for right-up)" 3
CFG[orientation_offset]=1
is "offset 1: left-up -> 2" "$(transform_for left-up)" 2
is "offset 1: right-up -> 0" "$(transform_for right-up)" 0
CFG[orientation_offset]=0 CFG[orientation_mirror]=true
is "mirror: left-up -> 3" "$(transform_for left-up)" 3
is "mirror: bottom-up stays 2" "$(transform_for bottom-up)" 2
CFG[orientation_mirror]=false CFG[orientation_offset]=09 CFG[debounce_ms]=08
is "a leading zero is decimal, not a bad octal number" "$(cfg_int debounce_ms 400)" 8
is "offset 09 turns like 1" "$(transform_for normal)" 1
CFG[orientation_offset]=0
is "lua_str escapes quotes" "$(lua_str 'a"b\c')" '"a\"b\\c"'
lua_str $'bad\nname' >/dev/null && fail "lua_str refuses control characters" || pass "lua_str refuses control characters"

echo
echo "Readers"
for name in $(grep -oE 'start_reader [a-z]+' "$CLI" | awk '{print $2}' | sort -u); do
  grep -qE "^  _$name-reader\) cmd__${name}_reader ;;" "$CLI" && grep -q "^cmd__${name}_reader()" "$CLI" &&
    pass "reader '$name' is defined and dispatched" || fail "reader '$name' has no _$name-reader command"
done

echo
echo "Widget"
# Qt 6.12's QtQuick has its own Color type, which shadows Omarchy's palette singleton.
grep -nE '(^|[^.A-Za-z])Color\.' "$HERE/../Widget.qml" >/dev/null &&
  fail "Widget.qml uses bare Color (write Commons.Color)" || pass "Widget.qml qualifies the palette as Commons.Color"

echo
echo "Release"
deployed=$(sed -n 's/^FILES=(\(.*\))$/\1/p' "$HERE/../scripts/deploy.sh")
shipped=" $(sed -n 's/^SHIP=(\(.*\))$/\1/p' "$HERE/../scripts/release.sh") "
missing=""
for item in $deployed; do [[ $shipped == *" $item "* ]] || missing+=" $item"; done
[[ -n $deployed && -z $missing ]] && pass "a release ships everything deploy.sh installs" || fail "release.sh would leave out:${missing:- (the lists could not be read)}"

echo
echo "PID files"
mkdir -p "$TMP/pids"
echo 1 >"$TMP/pids/one"
echo 0 >"$TMP/pids/zero"
echo $$ >"$TMP/pids/self"
echo "not-a-pid" >"$TMP/pids/junk"
[[ -z $(pid_of "$TMP/pids/one" systemd) ]] && pass "pid 1 is never trusted" || fail "pid 1 accepted"
[[ -z $(pid_of "$TMP/pids/zero" bash) ]] && pass "pid 0 is never trusted" || fail "pid 0 accepted"
[[ -z $(pid_of "$TMP/pids/junk" bash) ]] && pass "junk pid files are ignored" || fail "junk pid accepted"
[[ -z $(pid_of "$TMP/pids/self" _usb-reader) ]] && pass "a reused pid running something else is ignored" || fail "reused pid accepted"
[[ $(pid_of "$TMP/pids/self" bash) == "$$" ]] && pass "a live matching pid is accepted" || fail "live pid rejected"

echo
echo "Recipe review"
mkdir -p "$TMP/recipe"
echo 'pkgname=x' >"$TMP/recipe/PKGBUILD"
ln -s /etc/hostname "$TMP/recipe/sneaky.patch"
(build_reviewed "$TMP/recipe" </dev/null >/dev/null 2>&1) && fail "a recipe with a symlink is refused" || pass "a recipe with a symlink is refused"
rm "$TMP/recipe/sneaky.patch"
mkdir "$TMP/recipe/sub"
(build_reviewed "$TMP/recipe" </dev/null >/dev/null 2>&1) && fail "a recipe with a subfolder is refused" || pass "a recipe with a subfolder is refused"
rmdir "$TMP/recipe/sub"
mkdir "$TMP/builds"
out=$(TMPDIR="$TMP/builds" YES=1 build_reviewed "$TMP/recipe" </dev/null 2>&1)
[[ $out == *"Not installed"* ]] && pass "--yes never answers the build question" || fail "--yes skipped the recipe review (${out##*$'\n'})"
[[ -z $(ls -A "$TMP/builds") ]] && pass "the private build folder is removed when the build is declined" || fail "a build folder was left behind"
grep -q 'wl_callback_destroy(popup_draw_surf.frame_cb)' "$HERE/../packaging/wvkbd-deskus/hold-until-release.patch" &&
  pass "hiding cancels the key popup's frame callback (wvkbd crashed without it)" || fail "the hold patch no longer cancels the popup's frame callback"
grep -q 'wl_display_flush(display);' "$HERE/../packaging/wvkbd-deskus/hold-until-release.patch" &&
  pass "a keyboard the compositor closes is torn down through hide() (key released, flushed)" || fail "the close handler fix is missing from the hold patch"
grep -qx '  \[\[ \$name == .git \]\] && continue' "$HERE/../scripts/deploy.sh" &&
  pass "deploy keeps a plugin checkout's .git" || fail "deploy would delete .git from the plugin folder"
grep -q '^    sudo pacman -Rns wvkbd-deskus$' "$CLI" && ! grep -q 'pacman -Qq iio-sensor-proxy wvkbd wvkbd-deskus' "$CLI" &&
  pass "uninstall --packages removes only the keyboard the plugin built" || fail "uninstall --packages removes packages the plugin didn't install"
grep -qx 'KillMode=mixed' "$HERE/../systemd/omarchy-tablet-mode.service" &&
  pass "stopping the service signals the daemon first (KillMode=mixed)" || fail "the unit kills wvkbd before the daemon can hide it"

echo
echo "Menu entries"
MENU="$TMP/config/omarchy/extensions/omarchy-menu.jsonc"
printf '{\n  // a comment\n  "setup.x": {"when":"false"}\n}\n' >"$MENU"
cp "$MENU" "$TMP/menu.orig"
menu_add
grep -q '"trigger.toggle.tablet-mode"' "$MENU" && pass "entries added" || fail "entries missing"
grep -qx '  "setup.x": {"when":"false"}' "$MENU" && pass "the entry before the block is left untouched" || fail "the user's entry was edited"
grep -A1 '>>> tablet-mode' "$MENU" | tail -1 | grep -qx '  ,' && pass "the missing comma goes inside the block" || fail "no comma inside the block"
menu_add
is "adding twice keeps one block" "$(grep -c '>>> tablet-mode' "$MENU")" 1
sed -e 's#^[[:space:]]*//.*##' "$MENU" | python3 -c 'import json,re,sys; json.loads(re.sub(r",(\s*})", r"\1", sys.stdin.read()))' &&
  pass "still parses as JSONC" || fail "menu file no longer parses"
menu_remove
grep -q 'tablet-mode' "$MENU" && fail "entries removed" || pass "entries removed"
cmp -s "$MENU" "$TMP/menu.orig" && pass "removal leaves the file exactly as it was" || fail "removal changed the user's lines"

printf '{\n  "a.url": {"action":"open https://example.com"} // the last entry, no comma\n}\n' >"$MENU"
cp "$MENU" "$TMP/menu2.orig"
menu_add
jsonc_ok "$MENU" && pass "adds after an entry with a trailing comment and no comma" || fail "broke a menu whose last entry has a comment"
head -2 "$MENU" | tail -1 | grep -qF '// the last entry, no comma' && pass "the user's line is untouched" || fail "user's line was edited"
menu_remove
cmp -s "$MENU" "$TMP/menu2.orig" && pass "removal restores it byte for byte" || fail "removal left changes behind"

menu_add
sed -i '/<<< tablet-mode/d' "$MENU"
cp "$MENU" "$TMP/menu3.damaged"
menu_remove 2>/dev/null && fail "a damaged block is refused" || pass "a damaged block is refused"
cmp -s "$MENU" "$TMP/menu3.damaged" && pass "and the file is left alone (nothing deleted to the end)" || fail "damaged block: file was changed"
[[ -f $MENU.tablet-mode.bak ]] && cmp -s "$MENU.tablet-mode.bak" "$TMP/menu.orig" && pass "original kept as a backup" || fail "no backup"

mkdir -p "$TMP/cwd"
echo 'open("PWNED", "w")' >"$TMP/cwd/json.py"
(cd "$TMP/cwd" && jsonc_ok "$TMP/menu.orig") && [[ ! -e $TMP/cwd/PWNED ]] &&
  pass "jsonc_ok never imports modules from the current folder" || fail "jsonc_ok ran a json.py from the current folder"

# The user adds an entry after our block, relying on the comma inside it.
printf '{\n  "a.x": {"label":"A"}\n}\n' >"$MENU"
menu_add
sed -i '/<<< tablet-mode/a\  "b.x": {"label":"B"}' "$MENU"
menu_remove >/dev/null
jsonc_ok "$MENU" && pass "removal keeps the file parseable when a later entry needs our comma" || fail "removal broke the menu file"
grep -q '"b.x"' "$MENU" && ! grep -q 'tablet-mode' "$MENU" && pass "the user's later entry stays, our entries go" || fail "removal lost the user's entry or left ours"

menu_add
sed -i '0,/"a.x"/s//"a.x" BROKEN/' "$MENU"
cp "$MENU" "$TMP/menu4.broken"
menu_remove >/dev/null && fail "removal that can't leave a valid file is refused" || pass "removal that can't leave a valid file is refused"
cmp -s "$MENU" "$TMP/menu4.broken" && pass "and the file is left alone" || fail "an unparseable result was written"

grep -qF "\"$SELF status" <<<"$(menu_block)" && ! grep -qF "$LINK" <<<"$(menu_block)" &&
  pass "menu entries call the plugin's own script, not ~/.local/bin" || fail "menu entries go through ~/.local/bin/tablet-mode"
paths=$(env -u TABLET_MODE_OMARCHY_CONFIG XDG_CONFIG_HOME=/elsewhere bash -c 'source "$1"; echo "$MENU|$HOOK|$SHELL_JSON"' _ "$CLI")
is "Omarchy's files follow ~/.config/omarchy, not XDG_CONFIG_HOME" "$paths" "$HOME/.config/omarchy/extensions/omarchy-menu.jsonc|$HOME/.config/omarchy/hooks/theme-set.d/tablet-mode.sh|$HOME/.config/omarchy/shell.json"

# A dotfiles manager's symlink stays a link, and its target is what's edited and backed up.
MENU="$TMP/links/omarchy-menu.jsonc"
mkdir -p "$TMP/links" "$TMP/dotfiles"
printf '{\n  "a.x": {"label":"A"},\n}\n' >"$TMP/dotfiles/menu.jsonc"
cp "$TMP/dotfiles/menu.jsonc" "$TMP/menu5.orig"
ln -s "$TMP/dotfiles/menu.jsonc" "$MENU"
menu_add
[[ -f $MENU.tablet-mode.bak && ! -L $MENU.tablet-mode.bak ]] && cmp -s "$MENU.tablet-mode.bak" "$TMP/menu5.orig" &&
  pass "a symlinked menu is backed up by its contents" || fail "the backup of a symlinked menu is a link"
grep -q 'tablet-mode' "$TMP/dotfiles/menu.jsonc" && pass "entries are added to the link's target" || fail "the link's target wasn't edited"
menu_remove
[[ -L $MENU ]] && pass "removal leaves the symlink a symlink" || fail "removal replaced the symlink with a file"
cmp -s "$TMP/dotfiles/menu.jsonc" "$TMP/menu5.orig" && pass "and the target is back exactly as it was" || fail "our entries stayed in the dotfiles copy"

echo
rm -rf "$TMP"
echo "$PASS passed, $FAIL failed"
((FAIL == 0))
