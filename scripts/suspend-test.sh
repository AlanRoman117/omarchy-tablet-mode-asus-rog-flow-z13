#!/bin/bash

# Suspend isolation tests for the tablet-mode hang on the ROG Flow Z13 (2026-10-05):
# suspending with the keyboard detached and the accelerometer claimed never resumed.
# Each scenario turns the plugin off, sets up one ingredient at a time, and suspends
# with the kernel's suspend debugging on. A breadcrumb on disk survives a hard reset;
# `report` reads it back after a reboot. Diagnostic only: not deployed with the plugin.
#
# Usage: scripts/suspend-test.sh <sensor|detached|detached-sensor|osk> [--rehearse]
#        scripts/suspend-test.sh report

set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/tablet-mode-suspend-test"
LAST="$STATE_DIR/last"
HISTORY="$STATE_DIR/history.log"
KEYBOARD=0b05:1a30
POWER=/sys/power
PIDS=()
KNOBS_SET=0

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
note() { printf '  \033[33m•\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 <scenario> [--rehearse]
       $0 report

Scenarios (the tablet-mode plugin is turned off first):
  sensor           keyboard attached, accelerometer claimed (monitor-sensor)
  detached         keyboard detached, nothing claimed
  detached-sensor  keyboard detached, accelerometer claimed
  osk              keyboard attached, on-screen keyboard (wvkbd) shown
  detached-osk     keyboard detached, on-screen keyboard (wvkbd) shown
  plugin           the real thing: the plugin ON, keyboard detached, tablet mode
                   (checks that it releases the accelerometer and wvkbd before sleep)

--no-trace  a real suspend without pm_trace (pm_trace writes into the RTC and may
            itself wake the machine early). Wait about a minute before waking it.
--rehearse  pm_test=devices: every driver suspends and resumes, but the machine
            doesn't really sleep; it comes back by itself after 5 seconds. Low risk.
Without it: a real suspend with pm_trace on. If it hangs, hard reset, then run: $0 report
EOF
  exit 1
}

keyboard_state() {
  local dev
  for dev in /sys/bus/usb/devices/*; do
    [[ -f $dev/idVendor && -f $dev/idProduct ]] || continue
    [[ "$(<"$dev/idVendor"):$(<"$dev/idProduct")" == "$KEYBOARD" ]] && { echo attached; return; }
  done
  echo detached
}

battery_ok() {
  local bat capacity status
  for bat in /sys/class/power_supply/BAT*; do
    [[ -f $bat/capacity ]] || continue
    capacity=$(<"$bat/capacity") status=$(<"$bat/status")
    [[ $status == Discharging && $capacity -lt 30 ]] && return 1
  done
  return 0
}

stat_count() { cat "$POWER/suspend_stats/$1" 2>/dev/null || echo 0; }

knobs_reset() {
  sudo sh -c "echo none >$POWER/pm_test; echo 0 >$POWER/pm_trace; echo 0 >$POWER/pm_print_times; echo 0 >$POWER/pm_debug_messages" 2>/dev/null
}

# spawn_group <pidfile> <command...>: runs the command as its own session and process-group
# leader and records that process's pid. setsid(1) forks when it has to, so $! can't be
# trusted to name the group; a kill aimed at it would silently miss.
spawn_group() {
  local pidfile=$1
  shift
  rm -f "$pidfile"
  setsid bash -c 'echo $$ >"$0" && exec "$@"' "$pidfile" "$@" &
  for _ in {1..80}; do
    [[ -s $pidfile ]] && return 0
    sleep 0.025
  done
  return 1
}

cleanup() {
  local pid
  for pid in "${PIDS[@]}"; do kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null; done
  return 0
}

wait_for_keyboard() {
  local want=$1
  [[ $(keyboard_state) == "$want" ]] && return 0
  if [[ $want == detached ]]; then echo "  Detach the keyboard now."; else echo "  Attach the keyboard now."; fi
  for _ in $(seq 120); do
    [[ $(keyboard_state) == "$want" ]] && { ok "Keyboard $want"; return 0; }
    sleep 1
  done
  die "The keyboard is still $(keyboard_state)"
}

claim_sensor() {
  local o
  command -v monitor-sensor >/dev/null || die "monitor-sensor isn't installed (iio-sensor-proxy)"
  local log="$STATE_DIR/monitor-sensor.log"
  spawn_group "$STATE_DIR/monitor-sensor.pid" monitor-sensor --accel >"$log" 2>&1 || die "monitor-sensor didn't start"
  PIDS+=("$(<"$STATE_DIR/monitor-sensor.pid")")
  for _ in $(seq 20); do
    # Reported either as "orientation changed: X" or, when already known, "(orientation: X, tilt: ...)".
    o=$(grep -oE 'orientation( changed)?: (normal|left-up|right-up|bottom-up)' "$log" | tail -1)
    [[ -n $o ]] && { ok "Accelerometer claimed (${o##* })"; return 0; }
    sleep 0.25
  done
  die "monitor-sensor didn't report an orientation"
}

show_osk() {
  command -v wvkbd-mobintl >/dev/null || die "wvkbd isn't installed"
  spawn_group "$STATE_DIR/wvkbd.pid" wvkbd-mobintl >/dev/null 2>&1 || die "wvkbd didn't start"
  PIDS+=("$(<"$STATE_DIR/wvkbd.pid")")
  sleep 0.5
  kill -0 "${PIDS[-1]}" 2>/dev/null && ok "On-screen keyboard shown" || die "wvkbd didn't start"
}

# The plugin enters tablet mode about a second after the keyboard goes; wait for its
# accelerometer claim and on-screen keyboard so the suspend really has them active.
wait_for_tablet_mode() {
  for _ in $(seq 40); do
    if tablet-mode status --is tablet && pgrep -x monitor-sensor >/dev/null; then
      ok "Tablet mode: accelerometer claimed$(pgrep -x wvkbd-mobintl >/dev/null && echo ", on-screen keyboard up")"
      return 0
    fi
    sleep 0.25
  done
  die "The plugin didn't enter tablet mode (tablet-mode status)"
}

write_breadcrumb() {
  mkdir -p "$STATE_DIR"
  {
    echo "scenario=$1"
    echo "mode=$2"
    echo "started=$(date --iso-8601=seconds)"
    echo "boot_id=$(cat /proc/sys/kernel/random/boot_id)"
    echo "keyboard=$(keyboard_state)"
    echo "monitor_sensor=$(pgrep -x monitor-sensor >/dev/null && echo running || echo no)"
    echo "wvkbd=$(pgrep -x wvkbd-mobintl >/dev/null && echo running || echo no)"
    echo "tablet_mode_service=$(systemctl --user is-active omarchy-tablet-mode 2>/dev/null)"
    echo "kernel=$(uname -r)"
    echo "status=suspending"
  } >"$LAST"
  sync
}

# Kernel lines from this suspend worth reading: errors, sensor-hub drivers, slow devices.
summarize() {
  local since=$1
  step "Kernel log for this suspend"
  journalctl -k --no-pager -o short-monotonic --since "$since" 2>/dev/null |
    grep -iE 'amd_sfh|sfh|hid.sensor|iio|PM: |error|fail|timeout|returned -' |
    grep -vE 'returned 0 after' | tail -40
  step "Slowest devices (pm_print_times)"
  journalctl -k --no-pager --since "$since" 2>/dev/null |
    sed -nE 's/.*kernel: (.+): PM: ([a-z_]+) returned 0 after ([0-9]+) usecs.*/\3 \1 (\2)/p' | sort -rn | head -10 |
    awk '{ ms = $1 / 1000; $1 = ""; printf "  %8.1f ms %s\n", ms, $0 }'
}

run_scenario() {
  local scenario=$1 mode=$2 since before_ok before_fail
  case $scenario in sensor | detached | detached-sensor | osk | detached-osk | plugin) ;; *) usage ;; esac
  battery_ok || die "Battery below 30% and not charging; plug in first"
  mkdir -p "$STATE_DIR" || die "Can't create $STATE_DIR"
  [[ -w /dev/null && -t 0 ]] || die "Run this in a terminal"

  step "Suspend test: $scenario ($mode)"
  if [[ $mode != rehearse ]]; then
    echo "  This really suspends. Last time this kind of suspend needed a hard reset."
    echo "  Save your work in every app before going on."
  fi
  echo
  echo "  What happens:"
  echo "   1. Your password now, while the keyboard is attached (for the kernel's suspend-debug switches)."
  if [[ $scenario == plugin ]]; then
    echo "   2. The tablet-mode plugin is turned on; detaching the keyboard puts it in tablet mode."
  else
    echo "   2. The tablet-mode plugin is turned off; the scenario is set up."
  fi
  if [[ $scenario == detached* || $scenario == plugin ]]; then
    echo "   3. Detach the keyboard when asked. Nothing else needs typing from then on."
    echo "   4. A 10-second countdown, then it suspends by itself. To cancel, reattach the keyboard during the countdown."
  else
    echo "   3. A 10-second countdown, then it suspends by itself (Ctrl-C cancels)."
  fi
  if [[ $mode == notrace ]]; then
    echo "   Wake it: once the screen is dark, wait a full MINUTE, then tap the power button once."
    echo "   If the screen comes back on by itself before that, note roughly when."
    echo "   If it doesn't wake when you tap: hold the power button to force it off, turn it back on,"
    echo "   and run: $0 report"
  elif [[ $mode == real ]]; then
    echo "   Wake it: once the screen is dark, wait about 10 seconds, then tap the power button once."
    echo "   If it doesn't wake within a minute, hold the power button to force it off, turn it back on,"
    echo "   and run: $0 report"
  else
    echo "   The screen goes dark for about 5 seconds and comes back by itself."
  fi
  echo "   Afterwards, reattach the keyboard to read the results."
  echo
  sudo -v || die "Needs sudo"
  read -r -p "  Press Enter to start (Ctrl-C to cancel)... " _

  trap 'cleanup; ((KNOBS_SET)) && knobs_reset' EXIT
  if [[ $scenario == plugin ]]; then
    [[ $(tablet-mode setup-state 2>/dev/null) == ready ]] || tablet-mode enable >/dev/null 2>&1
    [[ $(tablet-mode setup-state 2>/dev/null) == ready ]] && ok "Tablet-mode plugin on" || die "The plugin didn't start (tablet-mode doctor)"
  elif systemctl --user is-active --quiet omarchy-tablet-mode || [[ $(tablet-mode setup-state 2>/dev/null) != disabled ]]; then
    tablet-mode disable >/dev/null 2>&1 && ok "Tablet-mode plugin turned off (tablet-mode enable brings it back)"
  fi

  # Set the debug switches now, while sudo can still be typed for.
  if [[ $mode == rehearse ]]; then
    sudo sh -c "echo 1 >$POWER/pm_print_times; echo 1 >$POWER/pm_debug_messages; echo devices >$POWER/pm_test" || die "Couldn't set the debug switches"
  elif [[ $mode == notrace ]]; then
    sudo sh -c "echo 1 >$POWER/pm_print_times; echo 1 >$POWER/pm_debug_messages" || die "Couldn't set the debug switches"
  else
    sudo sh -c "echo 1 >$POWER/pm_print_times; echo 1 >$POWER/pm_debug_messages; echo 1 >$POWER/pm_trace" || die "Couldn't set the debug switches"
  fi
  KNOBS_SET=1
  ok "Suspend-debug switches on ($(case $mode in rehearse) echo "pm_test=devices" ;; notrace) echo "timing only, no pm_trace" ;; *) echo "pm_trace" ;; esac))"

  case $scenario in
    sensor) wait_for_keyboard attached && claim_sensor ;;
    detached) wait_for_keyboard detached ;;
    detached-sensor) claim_sensor && wait_for_keyboard detached ;;
    osk) wait_for_keyboard attached && show_osk ;;
    detached-osk) show_osk && wait_for_keyboard detached ;;
    plugin) wait_for_keyboard detached && wait_for_tablet_mode ;;
  esac

  echo
  local left
  for left in 10 9 8 7 6 5 4 3 2 1; do
    printf '\r  Suspending in %2d s ' "$left"
    if [[ ($scenario == detached* || $scenario == plugin) && $(keyboard_state) == attached ]]; then
      echo
      die "Cancelled: the keyboard was reattached"
    fi
    sleep 1
  done
  echo

  write_breadcrumb "$scenario" "$mode"
  before_ok=$(stat_count success) before_fail=$(stat_count fail)
  since=$(date '+%Y-%m-%d %H:%M:%S')
  systemctl suspend

  # This process is frozen while asleep; it carries on after resume.
  for _ in $(seq 600); do
    (($(stat_count success) > before_ok || $(stat_count fail) > before_fail)) && break
    sleep 1
  done
  sleep 2
  knobs_reset
  KNOBS_SET=0

  local result=resumed slept
  slept=$(journalctl -k --no-pager -o short-unix --since "$since" 2>/dev/null |
    awk '/PM: suspend entry/ { e = $1 } /PM: suspend exit/ && e { printf "%.1f", $1 - e; exit }')
  (($(stat_count fail) > before_fail)) && result="failed ($(stat_count last_failed_dev) $(cat "$POWER/suspend_stats/last_failed_errno" 2>/dev/null))"
  # The kernel names the failed device; keep it to safe characters before it goes anywhere.
  result=$(printf '%s' "$result" | tr -c 'A-Za-z0-9 ._:()-' '_' | head -c 200)
  { grep -v '^status=' "$LAST"; echo "status=$result at $(date --iso-8601=seconds)"; } >"$LAST.tmp" && mv -f "$LAST.tmp" "$LAST"
  printf '%s %s %s: %s (asleep %s s)\n' "$(date --iso-8601=seconds)" "$scenario" "$mode" "$result" "${slept:-?}" >>"$HISTORY"
  sync

  step "Result"
  if [[ $result == resumed ]]; then ok "Suspended and resumed (asleep ${slept:-?} s)"; else bad "Suspend $result"; fi
  if [[ $mode != rehearse && -n $slept ]] && awk -v s="$slept" 'BEGIN { exit !(s < 10) }'; then
    bad "It woke by itself after $slept s, before deep sleep had a chance to matter: inconclusive"
    journalctl -k --no-pager --since "$since" 2>/dev/null | grep -E 'Triggering wakeup|Wakeup unrelated|wakeup IRQ' | sed 's/^/    /'
  fi
  summarize "$since"
  if [[ $mode == real ]]; then
    sudo systemctl restart systemd-timesyncd 2>/dev/null
    note "pm_trace scrambles the hardware clock; time sync was restarted. Check the clock in the bar."
  fi
  echo
  echo "Switches back to normal. History: $HISTORY"
  if [[ $scenario == plugin ]]; then
    step "What the plugin did"
    journalctl --user -u omarchy-tablet-mode --no-pager -o cat --since "$since" 2>/dev/null |
      grep -E 'sleep:|awake|mode \(|orientation' | sed 's/^/  /'
    tablet-mode status | sed -n '5,9p'
  else
    echo "The plugin is still off; turn it back on later with: tablet-mode enable"
  fi
}

cmd_report() {
  step "Last test"
  if [[ -f $LAST ]]; then
    sed 's/^/  /' "$LAST"
    if grep -q '^status=suspending' "$LAST"; then
      echo
      bad "It never came back from this suspend (hung)."
      [[ $(grep '^boot_id=' "$LAST" | cut -d= -f2) == "$(cat /proc/sys/kernel/random/boot_id)" ]] &&
        note "Same boot, though: the test may still be running in another terminal"
    fi
  else
    note "No test has run yet"
  fi

  step "pm_trace fingerprint (only after a hang with pm_trace on)"
  local hash
  hash=$(journalctl -b 0 -k --no-pager 2>/dev/null | grep -iE 'Magic number|hash matches' | sed 's/^/  /')
  if [[ -z $hash ]]; then
    note "None in this boot's kernel log"
  elif grep -q '^mode=real' "$LAST" 2>/dev/null && grep -q '^status=suspending' "$LAST"; then
    echo "$hash"
    note "The device after \"hash matches\" is the last one the kernel touched before the hang"
  else
    note "Ignored: the kernel prints a match on every boot; it only means something after a hung pm_trace test"
  fi

  step "Previous boot: last kernel lines"
  journalctl -b -1 -k --no-pager -o short-precise 2>/dev/null | tail -15 | cut -c1-160 | sed 's/^/  /'

  step "History"
  if [[ -f $HISTORY ]]; then sed 's/^/  /' "$HISTORY"; else note "Empty"; fi

  echo
  note "If the last test hung with pm_trace on, the clock may be wrong: sudo systemctl restart systemd-timesyncd"
}

case ${1:-} in
  report) cmd_report ;;
  sensor | detached | detached-sensor | osk | detached-osk | plugin)
    mode=real
    [[ ${2:-} == --rehearse ]] && mode=rehearse
    [[ ${2:-} == --no-trace ]] && mode=notrace
    run_scenario "$1" "$mode"
    ;;
  *) usage ;;
esac
