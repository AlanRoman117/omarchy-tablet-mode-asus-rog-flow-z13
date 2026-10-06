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

event() { "$CLI" send "$@" && sleep "${WAIT:-0.35}"; }
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
WAIT=1.1 event usb
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
grep -q SNAPSHOT-SENTINEL "$TMP/run/tweaks.lua" && fail "a reload retakes the snapshot" || pass "a reload retakes the snapshot"

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
WAIT=0.6 event "sleep post"
has "resume takes the delay lock again" "inhibit take"
has "resume claims the accelerometer again" "reader start sensor"
has "resume brings the keyboard back" "osk show"
is "awake in the state file" "$(state .asleep)" false

mark
echo attached >"$TMP/fixtures/keyboard"
WAIT=1.1 event usb
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
WAIT=0.6 event "sleep post"
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
is "lua_str escapes quotes" "$(lua_str 'a"b\c')" '"a\"b\\c"'
lua_str $'bad\nname' >/dev/null && fail "lua_str refuses control characters" || pass "lua_str refuses control characters"

echo
echo "Readers"
for name in $(grep -oE 'start_reader [a-z]+' "$CLI" | awk '{print $2}' | sort -u); do
  grep -qE "^  _$name-reader\) cmd__${name}_reader ;;" "$CLI" && grep -q "^cmd__${name}_reader()" "$CLI" &&
    pass "reader '$name' is defined and dispatched" || fail "reader '$name' has no _$name-reader command"
done

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

echo
rm -rf "$TMP"
echo "$PASS passed, $FAIL failed"
((FAIL == 0))
