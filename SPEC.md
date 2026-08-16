# Genesis — Behavior and Safety Contract

This document is the normative description of Genesis. Tests in `tests/`
exercise what can run without a Quattro machine; the rest is documented here for
manual verification.

## 1. Identity and loading

- `manifest.json` declares `schemaVersion: 1`, `id: "genesis"`, and
  `kinds: ["service", "bar-widget"]` with
  `entryPoints.service = "Service.qml"` and
  `entryPoints.barWidget = "BarWidget.qml"`.
- The shell loads `Service.qml` as a long-running service; it locates its own
  files via the shell-injected `manifest.__sourceDir`, falling back to the
  standard install path.
- The bar hosts `BarWidget.qml` as a bar-widget panel: a microphone button
  whose popup menu expands under the icon (`KeyboardPanel`, like the
  audio/bluetooth/power panels). Left-click talks; right-click toggles the
  menu, which offers a typed command and command-and-routine management. The same menu is
  summonable via `omarchy-shell shell toggle genesis '{}'`, which routes to the
  widget's `open()`.
- The bar widget holds no pipeline state and only sends IPC to the service;
  it must not register a second `genesis` IPC target (`manageIpc: false`).
- Genesis registers an IPC target named `genesis`. External callers use
  `omarchy-shell -q genesis <method>` (the `-q` is quiet best-effort: fire the
  call and ignore the result).

## 2. Input triggers

| Method | Signal | Contract |
|--------|--------|----------|
| `begin` | start recording | idempotent; caps the session at `maxListenSeconds` (10) |
| `end` | stop and process | no-op unless `phase == "listening"` |
| `toggle` | flip listening | `begin` if idle; otherwise stop — `end` while listening, cancel while thinking or confirming |
| `text <s>` | typed command | runs the intent pipeline on `<s>` directly |
| `state` | query | returns the current phase |

There is deliberately no `confirm` method: confirmation can only be answered
from the on-screen dialog (click or a spoken "yes" during the confirm phase), so
no local process — including a launched agent — can approve a destructive action
out of band.

Triggers map to these methods:

- Bar microphone left-click → `toggle`; right-click → toggles the popup menu
  (a bar-widget `KeyboardPanel` under the icon, offering a typed command or the
  manage submenu).
- A user-added keybind → `toggle` (or any other method).

Genesis registers no global keybinding of its own; any keyboard trigger is a
user-owned Hyprland binding, so no plugin installer is required.

## 3. Pipeline

The pipeline is fixed: capture → transcribe → intent → execute.

1. `begin` starts `pw-record` (or `parecord`/`arecord`) writing a 16 kHz mono
   WAV to `$XDG_RUNTIME_DIR/genesis/recording.wav`.
2. `end` stops the recorder (with a short flush delay) and runs
   `bin/transcribe <wav>`, which delegates to `voxtype transcribe` and deletes
   the WAV on success.
3. `bin/intent <text>` normalizes and matches rules, then the `commands`
   registry, and emits one JSON action object.
4. For actions named in `confirmActions`, Genesis pauses at a confirmation
   prompt instead of executing.
5. `bin/execute <json>` runs the mapped Omarchy command, coding-agent launch,
   plugin IPC call, shell command, or status query.

Each stage is a standalone script and fails closed: an unavailable backend or an
unparseable result yields no action rather than a guess. The overlay shows the
transcribed text while processing, so the user can confirm what was heard before
the action runs.

## 4. Action schema

`bin/intent` prints exactly one object on stdout:

```json
{"action":"shutdown","label":"Shut down the computer","needsConfirm":true,"args":{}}
```

- `action` is one of the known names (see README tables), `run`, `ipc`,
  `failed`, `agent`, or `unknown`.
- `needsConfirm` is derived from `confirmActions` in config; the `agent` action
  additionally always forces `true` (see §9).
- `args` carries extracted values: Home Assistant and TV actions carry a
  resolved `entity` or `command`; `ipc` carries `target`, `method`, and
  `params`; `run` carries `command`; `speak` carries `text`; `status` carries
  `type`; `failed` carries `phrase` and `error`; `agent` carries `prompt`.
- `unknown` never executes anything.

## 5. AI agent contract

- Unmatched text becomes an `agent` action only when `agent.enabled` is `true`;
  otherwise it becomes `unknown`. The default is `false` (agent disabled) — both
  the code default and the shipped `config.example.json` leave the agent off, so
  enabling it is a deliberate opt-in.
- `bin/execute` runs `omarchy-agent-prompt "<prompt>"`, launching the user's
  default coding agent with approval prompts bypassed. This is the security
  boundary of the plugin: anything the microphone hears that does not match a
  rule becomes an instruction an unrestricted agent acts on.
- Every `agent` action requires on-screen confirmation before launch: the
  dialog shows the transcribed (or typed) text and the user must approve — a
  misheard or ambient phrase cannot reach the agent silently.
- Command- and routine-management requests ("add a command…", "update my joke
  command", "change the 09:00 routine…") are routed to the agent with a hint
  pointing at `bin/commands` and `bin/routines` respectively. The prompt lists
  the currently registered entries, each with its full current definition, and
  instructs the agent to change only the one the user names — never create or
  touch unrelated entries.
- The popup menu's "Ask AI" (✨) — on the Commands/Routines lists and in the add
  forms — prefixes the typed request with `@command` or `@routine`; `bin/intent`
  strips the marker and instructs the agent to always register a command (or
  routine) with a short `--name`, never merely answer — and routes before the
  rules so even a phrase that looks like a built-in action becomes an entry.
- The edit forms' "Ask AI to update" (✨) prefixes with `@updatecommand <phrase>
  :: <change>` (or `@updateroutine <schedule> :: <change>`); `bin/intent` shows
  the entry's current spec and instructs the agent to apply only that change to
  that one entry — never create, rename, or touch another.
- The fallback prompt lists the built-in actions and the registered custom
  commands as tools, so the agent can dynamically interpret a request and invoke
  the right one. Built-ins are triggered by sending a phrase back through
  Genesis (`omarchy-shell -q genesis text "<phrase>"`), preserving confirmation;
  custom commands are invoked directly (`omarchy-shell <target> <method>` or
  the script).
- The agent is launched unattended but in its own terminal window; Genesis never
  answers on the agent's behalf and performs no privileged action itself.
- If no default agent is set, `omarchy-agent-prompt` exits non-zero and Genesis
  notifies the user to run `omarchy default agent <name>`.

## 6. Home Assistant contract (delegated)

- Genesis does not connect to Home Assistant itself; it forwards device actions
  to the community `hass` plugin over IPC (`omarchy-shell hass toggleEntity |
  activate <entity_id>`). The bare call (no `-q`) is deliberate: Genesis needs a
  non-zero exit to detect a missing plugin and notify the user.
- A spoken device name resolves through the `homeAssistant.entities` alias map:
  exact match, then substring, then word-subset (order-free). An unresolved name
  is never guessed — it falls through to `agent`.
- Only toggle (`ha-toggle`) and scene activation (`ha-scene`) are forwarded;
  fine-grained commands (brightness, set-points) fall through to the agent.
- No Home Assistant credentials live in Genesis; the token lives in the `hass`
  plugin.

## 7. TV contract (delegated)

- TV control is delegated to the Roku Remote and Apple TV Remote plugins —
  directly to the device, with no Home Assistant involved.
- `tv.backend` selects the target: `roku`, `apple-tv`, or `auto` (default:
  whichever plugin is installed, Roku first). `off` disables it.
- Commands are semantic (`power-on`, `power-off`, `play-pause`, `home`, `up`,
  `down`, `left`, `right`, `select`, `back`) and mapped per backend: Roku keys
  via `omarchy-shell -q roku sendKey <key>`, Apple TV actions via the plugin's
  `apple-tv-remote` CLI.
- TV power phrasings are matched before the system rules, so "power off the tv"
  reaches the TV and not `shutdown`.
- If no TV plugin is installed, Genesis notifies the user to install one.

## 8. Custom commands and routines

### Commands (`commands`)

- The `commands` config maps a stable id (a slug of the `name`, or the phrase)
  to either an `omarchy-shell` IPC call (`target`/`method`/`params`) or a script
  `run` in an optional `lang`. Each entry carries its own `phrase` (the trigger
  speech is matched against) and an optional `name` (display label).
- Matching runs after the built-in rules and before the agent fallback, by
  normalized word-boundary containment; the longest registered phrase wins.
- `ipc` actions run `omarchy-shell <target> <method> <params…>`. `run` actions
  write the snippet to a temp file and run it with the interpreter for `lang`
  (default `bash`; also `python`→`python3`, `node`→`node`, `ruby`→`ruby`);
  unknown or uninstalled languages are recorded as failures and blocked like
  any other command error. Genesis matches `params` statically; dynamic value
  extraction from speech is the AI agent's job (the commands are surfaced as
  tools, §5).
- Other plugins create/remove commands and routines by calling the `bin/commands`
  and `bin/routines` CLIs directly (they write `config.json` atomically), so
  registrations persist and are idempotent.
- `bin/commands export` / `bin/routines export` write their section as JSON (to
  stdout or a file); `bin/commands import <file>` / `bin/routines import <file>`
  merge a JSON object back in (same-key entries are overwritten; a routine
  import also reinstalls the timers). `routines import --dry-run <file>` and
  `config-import --dry-run '<json>'` preview what would be written and which
  timers would be installed, without changing anything. The menu's
  Export/Import do both sections at once, via the clipboard.

### Routines (`routines`)

- The `routines` config maps a stable id to a `run` command with an optional
  `lang`, an optional display `name`, and its `schedule` (the trigger).
  `bin/routines install` compiles each into persistent systemd user
  timers (a `.service`, `.timer`, and a `.sh` wrapper); `systemctl --user
  enable --now <name>.timer` makes them survive reboot and fire at the next
  scheduled time. The `.timer` suffix is mandatory — a bare name resolves to the
  `.service`, and `enable --now` on it would start (run) the routine on every
  install instead of arming the timer. There is deliberately no `Persistent=`
  catch-up — a routine must not fire the moment it is saved just because its
  schedule is earlier in the day.
- A bash routine's command is embedded in the `.sh` wrapper; a non-bash routine
  is written to a companion file (`<name>.<ext>`) the wrapper invokes with the
  matching interpreter.
- `bin/routines once [--lang …] <delay> <command>` and
  `bin/routines at [--lang …] <time> <command>` schedule one-off commands via
  transient `systemd-run` units (not persisted): `once` after a delay
  (`--on-active`), `at` at a wallclock time (`--on-calendar`). `bin/routines run
  <schedule>` runs a routine's stored command immediately (also a transient
  unit).
- Schedules are validated at `set` time; an invalid schedule is rejected.
- A routine's failure disables its own timer so a broken routine does not keep
  firing.

### Error blocking

- When a custom command or routine fails, Genesis records the error in
  `~/.local/state/genesis/errors.json`, notifies the user, and blocks the
  command: the next match emits a `failed` action instead of running it.
- Updating the command (`bin/commands set`/`run`) or routine (`bin/routines set`)
  clears the error and unblocks it.

### Activity log

- Every dispatched action is appended to `~/.local/state/genesis/log.json`
  (capped at 200 entries) via `log_action`; `run`/`ipc`/`failed` also record
  their outcome. View it with `bin/log` or the menu's "History"; clear it with
  `bin/log clear` (all) or `bin/log clear <phrase-or-schedule>` (one entry).
  The menu's History has a "Clear history" button, and each entry's edit form
  has its own "Clear history" for that entry alone.

## 9. Confirmation contract

- An action named in `confirmActions` (default: `shutdown`, `reboot`, `logout`,
  `suspend`) must pass explicit confirmation before `bin/execute` runs.
- The `agent` action always requires confirmation — independent of
  `confirmActions` — because it launches an approval-bypassed agent.
- Confirmation is satisfied by clicking the confirm button or by speaking a
  clear "yes" (`yes|yeah|yep|confirm|ok|okay|do it|sure|go ahead`).
- Any other transcript, a click on cancel, clicking the scrim, or a timeout
  cancels and returns to idle.
- Confirmation can only be answered from the dialog — Genesis exposes no IPC
  method that confirms out of band.
- Genesis never enables these actions at install time; each is reachable only
  through the normal pipeline + confirmation.
- Home Assistant, TV, and custom-command actions are non-destructive to the
  computer and do not require confirmation in v1.

## 10. Failures

- Pipeline failures are logged to the activity log (via `log_action`) and shown
  in the overlay ("Error: …") instead of silently resetting.
- No recorder available → `begin` still succeeds (the recorder command fails
  silently); an empty transcript shows "Didn't catch that" and returns to idle.
- Voxtype not installed → transcription fails; the error is shown and logged.
- Invalid intent JSON → ignored, returns to idle.
- `bin/execute` with an unknown action → prints an error, exits non-zero, and
  does nothing else.
- `hass` plugin not installed → Genesis notifies the user to install it.
- No TV plugin installed → Genesis notifies the user to install one.
- No TTS engine installed → `bin/speak` exits silently.

## 11. Idempotency and cleanup

- Installation is the standard `omarchy plugin add … --enable` flow, which
  starts the service and adds the bar button (the manifest defaults it to the
  right bar section).
- Genesis writes no files outside its own plugin directory, the config
  directory (`~/.config/genesis/config.json` — deliberately outside the plugin
  dir, since the shell hot-reloads any plugin whose directory changes), the
  runtime directory (`$XDG_RUNTIME_DIR/genesis`), the state directory
  (`~/.local/state/genesis`), and the systemd user unit directory
  (`~/.config/systemd/user/genesis-routine-*`).
- No Hyprland configuration is modified, and nothing needs to be removed beyond
  `omarchy plugin remove genesis` (and `bin/routines remove` for any installed
  timers).

## 12. Privileged capabilities

Genesis holds no credentials and performs no privileged action of its own. The
only system-level calls it ever makes are, on the user's request:

- `systemctl suspend` (the "suspend" action) and `systemctl --user` for its own
  `genesis-routine-*` timers (`bin/routines`). Omarchy has no suspend command of
  its own — suspend is logind's — so `systemctl suspend` is the idiomatic call.

Everything else is delegated to existing `omarchy-*` commands or plugin IPC.
