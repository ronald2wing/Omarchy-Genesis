#!/bin/bash

# Regression tests for the Genesis intent matcher. Runs `bin/intent` against a
# table of phrase -> expected action and fails on mismatch.
#
# Usage: tests/intent.sh

set -uo pipefail

PLUGIN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
INTENT="$PLUGIN_DIR/bin/intent"
export GENESIS_CONFIG="$PLUGIN_DIR/tests/fixtures/config.json"

pass=0
fail=0

check() {
  local phrase="$1" expected="$2"
  local got
  got=$("$INTENT" "$phrase" | jq -r '.action // "unknown"')
  if [[ $got == "$expected" ]]; then
    (( pass += 1 ))
  else
    (( fail += 1 ))
    printf 'FAIL: %-40s expected=%-16s got=%s\n' "\"$phrase\"" "$expected" "$got"
  fi
}

# destructive / system
check "shut down the computer" shutdown
check "shutdown" shutdown
check "power off" shutdown
check "power down" shutdown
check "turn off the computer" shutdown
check "turn off my pc" shutdown
check "switch off the machine" shutdown
check "reboot" reboot
check "restart the computer" reboot
check "log out" logout
check "sign out" logout
check "lock the screen" lock
check "lock the computer" lock
check "go to sleep" suspend
check "suspend" suspend

# bare "sleep" must NOT suspend the machine (any sentence containing "sleep")
check "play some sleep sounds" agent
check "sleep" agent

# destructive / system — alternate phrasings
check "shut the computer down" shutdown
check "shut my laptop down" shutdown
check "shut it down" shutdown
check "turn the computer off" shutdown
check "turn off the system" shutdown
check "turn off the device" shutdown
check "switch the computer off" shutdown
check "power off the computer" shutdown
check "power down the system" shutdown
check "reboot the system" reboot
check "restart my pc" reboot
check "restart the system" reboot
check "log off" logout
check "sign me out" logout
check "lock the device" lock
check "lock my pc" lock
check "put the computer to sleep" suspend
check "put it to sleep" suspend
check "hibernate" suspend

# confirmation contract: destructive actions needConfirm, benign ones don't
for a in shutdown reboot logout suspend; do
  got=$("$INTENT" "$a" | jq -r '.needsConfirm')
  [[ $got == "true" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected=true got=%s\n' "\"$a needsConfirm\"" "$got"; }
done
got=$("$INTENT" "take a screenshot" | jq -r '.needsConfirm')
[[ $got == "false" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected=false got=%s\n' "\"screenshot needsConfirm\"" "$got"; }

# capture
check "take a screenshot" screenshot
check "screenshot" screenshot
check "take a picture of the screen" screenshot
check "screen capture" screenshot

# audio
check "turn the volume up" volume-up
check "louder" volume-up
check "increase volume" volume-up
check "raise the volume" volume-up
check "turn up the volume" volume-up
check "volume down" volume-down
check "quieter" volume-down
check "lower the volume" volume-down
check "turn down the volume" volume-down
check "mute" mute
check "unmute" mute
check "mute the volume" mute

# brightness
check "brightness up" brightness-up
check "increase brightness" brightness-up
check "brighter" brightness-up
check "raise the brightness" brightness-up
check "turn up the brightness" brightness-up
check "brightness down" brightness-down
check "dimmer" brightness-down
check "lower the brightness" brightness-down
check "turn down the brightness" brightness-down

# extras (TTS, toggles, status)
check "say hello world" speak
check "toggle night light" nightlight
check "stay awake" idle
check "allow idle" idle
check "power mode performance" power-profile
check "power profile power saver" power-profile
check "go to workspace 3" workspace
check "set theme to Tokyo Night" theme
check "battery status" status
check "what time is it" status
check "whats playing" status

# launch
check "open firefox" open
check "launch spotify" open
check "run kitty" open
check "open the terminal" open

# reminder
check "remind me in 15 minutes to pickup jack" reminder
check "remind me to call mom" reminder
check "set a reminder to buy milk" reminder
check "remind me in 5 minutes" reminder

# "remind me in N minutes" without a message still sets the N-minute timer
got=$("$INTENT" "remind me in 5 minutes" | jq -r '.args.minutes')
[[ $got == "5" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected=%-16s got=%s\n' "\"reminder minutes (no msg)\"" "5" "$got"; }

# media
check "play music" media-play
check "pause the music" media-pause
check "next song" media-next
check "previous track" media-previous
check "play a song" media-play
check "play some music" media-play
check "pause the song" media-pause
check "stop the music" media-pause
check "next track" media-next
check "prev" media-previous

# home assistant (delegated to the hass plugin)
check "turn on the living room lights" ha-toggle
check "switch off the bedroom lights" ha-toggle
check "toggle the living room lights" ha-toggle
check "turn off the lights in the office" ha-toggle
check "activate movie mode" ha-scene
check "run the movie" ha-scene

# tv (delegated to the Roku / Apple TV remote plugins)
check "turn on the tv" tv
check "turn off the apple tv" tv
check "tv on" tv
check "roku off" tv
check "pause the tv" tv
check "tv home" tv
check "home screen" tv
check "tv up" tv
check "tv select" tv
check "tv back" tv
check "power off the tv" tv
check "turn the tv off" tv
check "power on the roku" tv

# tv command mapping
got=$("$INTENT" "turn off the tv" | jq -r '.args.command')
[[ $got == "power-off" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected=%-16s got=%s\n' "\"tv off command\"" "power-off" "$got"; }
got=$("$INTENT" "turn the tv off" | jq -r '.args.command')
[[ $got == "power-off" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected=%-16s got=%s\n' "\"tv off command (split)\"" "power-off" "$got"; }
got=$("$INTENT" "tv ok" | jq -r '.args.command')
[[ $got == "select" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected=%-16s got=%s\n' "\"tv ok command\"" "select" "$got"; }

# phrases too specific for the hass plugin fall through to the agent
check "set the living room lights to 50 percent" agent
check "set the thermostat to 72" agent

# custom commands (plugin IPC registry)
check "toggle do not disturb" ipc
check "please toggle do not disturb" ipc
check "movie time" run
check "check disk space" run

# custom command payload
got=$("$INTENT" "toggle do not disturb" | jq -r '.args.target')
[[ $got == "notifications" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected=%-16s got=%s\n' "\"custom target\"" "notifications" "$got"; }

# a non-bash command carries its language through to execute
got=$("$INTENT" "check disk space" | jq -r '.args.lang')
[[ $got == "python" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected=%-16s got=%s\n' "\"custom lang\"" "python" "$got"; }

# a bash command has no language (defaults to bash in execute)
got=$("$INTENT" "movie time" | jq -r '.args.lang')
[[ $got == "" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected=%-16s got=%s\n' "\"default lang\"" "empty" "$got"; }

# an errored command is blocked (emits "failed", not "run")
state_tmp=$(mktemp -d)
mkdir -p "$state_tmp/genesis"
printf '%s' '{"commands":{"movie time":{"error":"boom"}}}' > "$state_tmp/genesis/errors.json"
got=$(XDG_STATE_HOME="$state_tmp" "$INTENT" "movie time" | jq -r '.action // "unknown"')
if [[ $got == "failed" ]]; then
  (( pass += 1 ))
else
  (( fail += 1 ))
  printf 'FAIL: %-40s expected=%-16s got=%s\n' "\"errored command blocked\"" "failed" "$got"
fi

# unmatched text routes to the AI agent (fixture has agent.enabled: true)
check "what is the meaning of life" agent
check "summarize this project" agent
check "turn on the garden sprinklers" agent
check "set a routine to run the backup at 8am" agent

# agent requests require on-screen confirmation (the agent runs approval-bypassed)
got=$("$INTENT" "what is the meaning of life" | jq -r '.needsConfirm')
[[ $got == "true" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected=true got=%s\n' "\"agent needsConfirm\"" "$got"; }

# the agent fallback prompt lists registered custom commands as tools
got=$("$INTENT" "turn on the garden sprinklers" | jq -r '.args.prompt' | grep -c 'omarchy-shell notifications toggleDnd' || true)
[[ $got == "1" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected tool in prompt\n' "\"agent tools\""; }

# ...and the built-in actions as triggerable phrases
got=$("$INTENT" "turn on the garden sprinklers" | jq -r '.args.prompt' | grep -c 'shut down the computer' || true)
[[ $got == "1" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected builtin in prompt\n' "\"agent builtins\""; }

# routine requests carry a bin/routines hint in the agent prompt
got=$("$INTENT" "set a routine to run the backup at 8am" | jq -r '.args.prompt' | grep -c 'bin/routines' || true)
[[ $got == "1" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected hint in prompt\n' "\"routine hint\""; }

# command-management requests carry a bin/commands hint in the agent prompt
check "add a command to launch the music app" agent
got=$("$INTENT" "add a command to launch the music app" | jq -r '.args.prompt' | grep -c 'bin/commands' || true)
[[ $got == "1" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected hint in prompt\n' "\"command hint\""; }

# voice updates list the existing entries so the agent targets the specific
# command/routine the user names instead of recreating it
check "update my joke command" agent
got=$("$INTENT" "update my joke command" | jq -r '.args.prompt' | grep -c 'Existing commands' || true)
[[ $got -ge 1 ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected existing list\n' "\"update command lists\""; }
got=$("$INTENT" "update my joke command" | jq -r '.args.prompt' | grep -c 'toggle do not disturb' || true)
[[ $got -ge 1 ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected command entry\n' "\"update command entry\""; }
got=$("$INTENT" "update my joke command" | jq -r '.args.prompt' | grep -c '{"phrase":"toggle do not disturb"' || true)
[[ $got -ge 1 ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected full spec\n' "\"update command full spec\""; }
check "change my 09:00 routine to 08:00" agent
got=$("$INTENT" "change my 09:00 routine to 08:00" | jq -r '.args.prompt' | grep -c 'Existing routines' || true)
[[ $got -ge 1 ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected existing list\n' "\"update routine lists\""; }
got=$("$INTENT" "change my 09:00 routine to 08:00" | jq -r '.args.prompt' | grep -c '08:00' || true)
[[ $got -ge 1 ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected routine entry\n' "\"update routine entry\""; }
got=$("$INTENT" "change my 09:00 routine to 08:00" | jq -r '.args.prompt' | grep -c '{"schedule":"08:00"' || true)
[[ $got -ge 1 ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected full spec\n' "\"update routine full spec\""; }

# panel-menu "Ask AI" markers force command/routine registration via the agent
check "@command toggle do not disturb" agent
got=$("$INTENT" "@command toggle do not disturb" | jq -r '.args.prompt' | grep -c 'bin/commands' || true)
[[ $got -ge 1 ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected hint in prompt\n' "\"@command hint\""; }
got=$("$INTENT" "@command toggle do not disturb" | jq -r '.args.prompt' | grep -c 'ALWAYS register a command' || true)
[[ $got == "1" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected always-register\n' "\"@command always\""; }
got=$("$INTENT" "@command toggle do not disturb" | jq -r '.args.prompt' | grep -c 'Request: toggle do not disturb' || true)
[[ $got == "1" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected stripped request\n' "\"@command strip\""; }
got=$("$INTENT" "@command toggle do not disturb" | jq -r '.args.prompt' | grep -c -- '--name' || true)
[[ $got -ge 1 ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected --name in howto\n' "\"@command name\""; }
got=$("$INTENT" "@command toggle do not disturb" | jq -r '.args.prompt' | grep -c 'give it a short --name' || true)
[[ $got -ge 1 ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected name instruction\n' "\"@command name instruction\""; }

check "@routine run the backup at 8am" agent
got=$("$INTENT" "@routine run the backup at 8am" | jq -r '.args.prompt' | grep -c 'bin/routines' || true)
[[ $got -ge 1 ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected hint in prompt\n' "\"@routine hint\""; }
got=$("$INTENT" "@routine run the backup at 8am" | jq -r '.args.prompt' | grep -c 'ALWAYS register a routine' || true)
[[ $got == "1" ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected always-register\n' "\"@routine always\""; }
got=$("$INTENT" "@routine run the backup at 8am" | jq -r '.args.prompt' | grep -c 'routines set' || true)
[[ $got -ge 1 ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected routines CLI in howto\n' "\"@routine CLI\""; }

# the markers route to the agent even when agent.enabled is false ("always create")
got=$(GENESIS_CONFIG="$PLUGIN_DIR/tests/fixtures/config-no-agent.json" \
  "$INTENT" "@command launch kitty" | jq -r '.action // "unknown"')
if [[ $got == "agent" ]]; then
  (( pass += 1 ))
else
  (( fail += 1 ))
  printf 'FAIL: %-40s expected=%-16s got=%s\n' "\"@command agent disabled\"" "agent" "$got"
fi

# the edit-form markers name the entry being updated and show its current spec
check "@updatecommand movie time :: change it to launch vlc" agent
got=$("$INTENT" "@updatecommand movie time :: change it to launch vlc" | jq -r '.args.prompt' | grep -c 'Current command "movie time"' || true)
[[ $got -ge 1 ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected current spec\n' "\"@updatecommand spec\""; }
got=$("$INTENT" "@updatecommand movie time :: change it to launch vlc" | jq -r '.args.prompt' | grep -c 'Change requested: change it to launch vlc' || true)
[[ $got -ge 1 ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected change text\n' "\"@updatecommand change\""; }
check "@updateroutine 08:00 :: run at 09:00 instead" agent
got=$("$INTENT" "@updateroutine 08:00 :: run at 09:00 instead" | jq -r '.args.prompt' | grep -c 'Current routine "08:00"' || true)
[[ $got -ge 1 ]] && (( pass += 1 )) || { (( fail += 1 )); printf 'FAIL: %-40s expected current spec\n' "\"@updateroutine spec\""; }

# with the agent disabled, unmatched text is unknown
got=$(GENESIS_CONFIG="$PLUGIN_DIR/tests/fixtures/config-no-agent.json" \
  "$INTENT" "what is the meaning of life" | jq -r '.action // "unknown"')
if [[ $got == "unknown" ]]; then
  (( pass += 1 ))
else
  (( fail += 1 ))
  printf 'FAIL: %-40s expected=%-16s got=%s\n' "\"agent disabled\"" "unknown" "$got"
fi

echo
echo "passed: $pass  failed: $fail"
(( fail == 0 )) || exit 1
