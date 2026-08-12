# Repository Guidelines

Genesis is an Omarchy Quattro voice-assistant plugin (`id: "genesis"`). No build
step — QML loaded by `omarchy-shell` plus shell scripts in `bin/`.

## Verify

```bash
bash tests/validate.sh   # manifest schema, bash -n (bin/*), python syntax, JSON
bash tests/intent.sh     # intent matcher + entity resolution + error-blocking
bash tests/routine.sh    # one-off scheduling (once/at) via a stubbed systemd-run
bash tests/config.sh     # command/routine export + import (stubbed systemctl)
```

`omarchy plugin validate .` requires a Quattro machine (not available here).
`qmllint Service.qml BarWidget.qml` runs locally (Qt tooling is installed).

## Architecture

- Pipeline: `capture` → `transcribe` → `intent` → `execute`. `Service.qml` only
  orchestrates and renders the overlay; all logic lives in `bin/`.
- `intent` emits one JSON object `{action,label,needsConfirm,args}`; `execute`
  dispatches on `action`. Adding a voice command = a rule in `intent` + a case
  in `execute`.
- **Delegate, don't reimplement.** Call the existing tool for anything Omarchy
  already provides: `omarchy-*` commands (shutdown/volume/brightness/
  screenshot/reminder), `omarchy-shell <target> <method>` IPC (the `hass`, Roku,
  Apple TV, `media` plugins), `voxtype transcribe` (STT), `omarchy-agent-prompt`
  (AI), and `systemd` timers (routines).
- Two user-extensible layers live in `config.json`: `commands` (phrase → plugin
  IPC or script `run`, with optional `lang`) and `routines` (schedule → `run`
  (+`lang`), compiled to systemd timers). Both are managed by `bin/commands`,
  `bin/routines`, and the QML popup menu (in `BarWidget.qml`), and can be created
  by voice (the agent gets a hint in `bin/intent`). `lang` values: `bash`
  (default), `python`, `node`, `ruby` — resolved by `lang_info` in `lib.sh`.

## Config & state

- Config path: `~/.config/genesis/config.json` (`${XDG_CONFIG_HOME:-~/.config}/genesis/config.json`),
  overridden by `GENESIS_CONFIG` (tests point it at `tests/fixtures/config.json`).
  It deliberately lives **outside** the plugin dir — the Omarchy shell hot-reloads
  any plugin whose directory changes, so writing config.json inside
  `~/.config/omarchy/plugins/genesis/` would tear down the bar widget and close
  the popup menu. Never edit it raw from a script — use `config_write` in
  `lib.sh` (atomic jq write).
- Error store: `~/.local/state/genesis/errors.json` via `set_error`/`clear_error`
  in `lib.sh`. A failing custom command/routine is recorded, notifies the user,
  and is **blocked** — `intent` returns a `failed` action for it until
  `commands set/run` (or `routines set`) clears the error.
- Activity log: `~/.local/state/genesis/log.json` via `log_action` (capped to 200
  entries); view with `bin/log`, clear with `bin/log clear` (all) or
  `bin/log clear <phrase-or-schedule>` (one entry); the menu's History and each
  entry's edit form both have a "Clear history" button.
- `confirmActions` (default `shutdown reboot logout suspend`) gates those
  actions behind a confirm dialog. There is deliberately no IPC `confirm`
  method — confirmation is only answerable from the dialog, so a launched agent
  (or any local process) cannot approve a destructive action out of band.

## Gotchas (easy to get wrong)

- `json_write <file> [--arg …] <filter>`: the filter is the **last** argument;
  `--arg` options come first. Never bind a jq `as $x` variable to a name also
  passed via `--arg x` — the `as` shadows the arg (this silently stored
  `run: {}`).
- `local` is only valid inside a function; `bin/execute`'s `case` body is
  top-level, so use plain variables there.
- The plugin id `genesis` is hardcoded in several paths: `lib.sh` `PLUGIN_ID`,
  `wake-word.py` `CONFIG`, `BarWidget.qml` `moduleName` and its `pluginDir`
  (bar widgets get no `manifest` injection), and the fallback in `Service.qml`
  `pluginDir` (which prefers the shell-injected `manifest.__sourceDir`).
  Renaming is not just a `manifest.json` edit.
- `Service.qml` `wavPath` must match `CAPTURE_WAV` in `lib.sh` (both
  `$XDG_RUNTIME_DIR/genesis/recording.wav`).
- `notify()` (in `lib.sh`) takes one message argument; the title is always
  "Genesis".
- `omarchy-shell -q` is quiet best-effort (suppress output, return success on
  failure). Use it only for fire-and-forget calls; use a bare `omarchy-shell`
  call in an `if !` where failure must be detected (see `hass_call`/`ipc`).
- `lang_info` (in `lib.sh`) prints its result with a trailing newline. Reading
  it with `read` from a process substitution relies on that — a missing newline
  makes `read` return 1 (EOF) even though it read the data, which surfaces as a
  spurious "unknown language" failure.
- In `bin/intent`, TV power rules must stay above the `shutdown` rule so
  "power off the tv" reaches the TV, not shutdown.
- `bin/routines` must call `systemctl --user enable --now <name>.timer` (keep the
  `.timer` suffix). `$(basename "$t" .timer)` strips it, and a bare unit name
  resolves to the `.service` — whose `--now` *starts* it, running the routine on
  every import/install instead of just arming the timer. `tests/config.sh`
  asserts the `.timer` suffix.

## Conventions

- Shell: `#!/bin/bash`, `set -euo pipefail` (`set -uo pipefail` in tests), two
  spaces, `[[ ]]` / `(( ))`, quote expansions. Source `bin/lib.sh` for shared
  helpers (`have`, `notify`, `config_get`, `config_write`, `resolve_entity`,
  error helpers).
- QML: `qs.Commons` / `qs.Ui` tokens only (`Style`, `Color`, `Border`, `Util`,
  `BarWidget`, `BarIconButton`, `KeyboardPanel`, `ConfirmDialog`,
  `BorderSurface`). `Service.qml` reads its dir from the injected
  `manifest.__sourceDir`. Reusable popup pieces are inline `component`s in
  `BarWidget.qml` (`RowBtn`, `Btn`, `Input`, `TextArea`, `MenuRow`, `RunBtn`,
  `ListRow`, `Segmented`, `EmptyState`).
- Python: standard library only, except the openWakeWord stack installed into
  its own venv.

## Tests & commits

- Intent/rule change → add a `tests/intent.sh` case (phrase → action, plus
  `.args.*` checks where the payload matters).
- New script, manifest field, or entry point → extend `tests/validate.sh`.
- Keep `README.md`, `SPEC.md`, and `config.example.json` in sync.
- Conventional Commit subjects; destructive-action changes must state how the
  confirmation contract in `SPEC.md` is preserved.
