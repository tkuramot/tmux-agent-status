# tmux-agent-status

Show what your AI coding agents are doing — waiting for approval, working,
finished — in the tmux status line, per pane, per window and in total.

The agent reports state changes through its own hooks, so nothing is polled:
the status line reads tmux options that change only when something happens.

```
0 zsh  1 api (waiting)  2 web (working)  3 docs (done)  4 sh (idle)    (waiting)1 (working)1 (done)1
```

## How it works

There are three layers, and only the adapter knows anything about a
particular agent:

| Layer | File | Role |
| --- | --- | --- |
| Core | `scripts/agent-status` | Agent-agnostic CLI. Stores each pane's state in a pane option and keeps the server-wide summary. |
| Adapter | `adapters/<agent>/map` | The only agent-specific file: maps the agent's events to states, and generates the agent's hook settings. |
| Plugin | `agent-status.tmux` | Expands the `#{agent_*}` placeholders and registers tmux hooks. |

Window state is computed by tmux from the window's panes at draw time, and
state changes are compare-and-set operations inside tmux, so concurrent hooks
cannot leave stale values behind.

States, highest priority first (a window shows the highest state of its panes):

| State | Meaning |
| --- | --- |
| `waiting` | The agent needs you (e.g. a permission prompt). |
| `error` | The agent stopped on an error. |
| `working` | The agent is busy. |
| `done` | The agent finished and you have not looked at the pane yet. |
| `idle` | The agent is running and waiting for input. |

A `done` pane becomes `idle` when you switch to it, or immediately if it is
already the visible pane (see `@agent-status-auto-seen`).

## Requirements

- tmux 3.8 or later
- bash 3.2 or later (the macOS system bash works)

## Installation

### With [TPM](https://github.com/tmux-plugins/tpm)

```tmux
set -g @plugin 'tkuramot/tmux-agent-status'
```

Press `prefix + I` to install.

### Manually

```sh
git clone https://github.com/tkuramot/tmux-agent-status ~/.tmux/plugins/tmux-agent-status
```

```tmux
run-shell ~/.tmux/plugins/tmux-agent-status/agent-status.tmux
```

Set the formats that use the placeholders **before** the plugin is loaded
(before `run '~/.tmux/plugins/tpm/tpm'`).

## Status line

```tmux
set -g window-status-format         '#I #W#{?#{agent_state}, #{agent_status},}'
set -g window-status-current-format '#I #W#{?#{agent_state}, #{agent_status},}'
set -g status-right '#{agent_summary}'
```

| Placeholder | Expands to |
| --- | --- |
| `#{agent_status}` | Icon for the window's aggregate state. |
| `#{agent_state}` | The window's aggregate state name (empty if no agent). |
| `#{agent_pane_status}` | Icon for the pane's state (for `pane-border-format`). |
| `#{agent_pane_state}` | The pane's state name. |
| `#{agent_summary}` | Icon and count per state across the server, e.g. `(waiting)1 (working)2`. |

Placeholders are expanded in the **global** values of `status-left`,
`status-right`, `window-status-format`, `window-status-current-format` and
`pane-border-format`; session or window-local values are left alone. The state names work in conditionals, for example to
highlight windows waiting for approval:

```tmux
set -g window-status-format '#{?#{==:#{agent_state},waiting},#[bg=red],}#I #W'
```

## Session and window tree

`prefix s` and `prefix w` (`choose-tree`) show each session's, window's and
pane's state after its name. The plugin rebinds these keys only while they
have tmux's default binding; set `@agent-status-choose-tree` to `off` to keep
tmux's own format. For your own `choose-tree` bindings, use the same format:

```tmux
bind-key s choose-tree -s -F '#{E:@agent-status_tree_format}'
```

## Agents

### Claude Code

Hook settings are generated from the adapter map. Print them:

```sh
~/.tmux/plugins/tmux-agent-status/scripts/agent-status hooks claude-code
```

Merge them into `~/.claude/settings.json` with `jq`. Your other hooks keep
their order, entries from a previous install (any path) are replaced, and a
symlinked file stays a symlink:

```sh
AS=~/.tmux/plugins/tmux-agent-status/scripts/agent-status
f=~/.claude/settings.json
[ -f "$f" ] || echo '{}' >"$f"
merge='
  def ours: any(.hooks[]?; .command | contains("/scripts/agent-status"));
  .hooks = ((.hooks // {}) | map_values(map(select(ours | not))) as $kept
    | reduce ($new.hooks | keys[]) as $k ($kept; .[$k] = ((.[$k] // []) + $new.hooks[$k])))'
new="$(jq --argjson new "$("$AS" hooks claude-code)" "$merge" "$f")" && printf '%s\n' "$new" >"$f"
```

Event mapping (`adapters/claude-code/map`):

| Claude Code event | State |
| --- | --- |
| `SessionStart` (`startup`, `resume`, `clear`) | `idle` |
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure` | `working` |
| `Notification` (`permission_prompt`, `elicitation_dialog`) | `waiting` |
| `Stop` | `done` |
| `StopFailure` | `error` |
| `SessionEnd` (except `clear`) | cleared |

- `SessionStart` with `compact` is not hooked because it can fire mid-turn.
- Interrupting Claude with Esc fires no hook (not even `idle_prompt` later),
  so the pane stays `working` until the next prompt. Detecting it would need
  polling, which this plugin avoids.
- Subagents report through the same pane: while a background subagent runs
  after the main turn has ended, the pane shows `working`.

### Adding another agent

1. Create `~/.config/tmux-agent-status/adapters/<agent>/map` (or
   `adapters/<agent>/map` in this repository to contribute it):

   ```
   # <event>[:<matcher>] <state|clear> [<from-state>,...]
   task_started   working
   needs_approval waiting
   task_complete  done
   idle_timeout   idle     working,waiting
   ```

   - One entry per line; `#` starts a comment line.
   - The optional third field applies the action only when the pane is
     currently in one of those states.
   - Events are matched exactly. `Event` and `Event:matcher` entries cannot be
     mixed for the same event, since both hooks would fire. Matchers are passed
     to the agent as-is, so `check` cannot detect overlapping patterns such as
     `Bash` and `Bash|Edit`.
   - A user map replaces the built-in map of the same name.

   Validate it with `agent-status check <agent>`. This matters because `emit`
   ignores invalid entries silently.

2. Call `agent-status emit <agent> <event>` from the agent's hooks.
   `agent-status hooks <agent>` prints Claude Code style settings; for other
   agents, wire the calls up in whatever form the agent expects.

`emit` is safe inside any agent's hook: it drains stdin without waiting for it
to close, prints nothing and always exits 0. Outside tmux it does nothing.

Why a plain text map rather than JSON or YAML: `emit` runs on every hook, and
this format is read by bash alone with no `jq`/`yq` dependency or startup
cost, while staying easy to diff and grep.

Agents without hooks can be wrapped and set states directly:

```sh
agent-status set working --agent my-agent
my-agent "$@"; rc=$?
if [ "$rc" -eq 0 ]; then agent-status set done; else agent-status set error; fi
```

## Options

| Option | Default | Description |
| --- | --- | --- |
| `@agent-status-icon-waiting` | `(waiting)` | Icon for `waiting`. |
| `@agent-status-icon-error` | `(error)` | Icon for `error`. |
| `@agent-status-icon-working` | `(working)` | Icon for `working`. |
| `@agent-status-icon-done` | `(done)` | Icon for `done`. |
| `@agent-status-icon-idle` | `(idle)` | Icon for `idle`. |
| `@agent-status-summary-states` | `waiting error working done` | States counted in `#{agent_summary}`, in order. |
| `@agent-status-summary-separator` | ` ` (space) | Separator between summary entries. |
| `@agent-status-auto-seen` | `on` | Turn `done` into `idle` once the pane is viewed in an attached session. |
| `@agent-status-jump-key` | *(unset)* | Key (after prefix) bound to `jump`. It replaces any existing binding of that key, and is not unbound if the option is removed later. |
| `@agent-status-choose-tree` | `on` | Show states in `prefix s` / `prefix w` (see [Session and window tree](#session-and-window-tree)). |
| `@agent-status-jump-states` | `waiting error done` | States `jump` looks for, in order. |

Icon changes apply on the next redraw. An empty value means the default; to
hide a state, set its icon to `#[]`.

About the defaults:

- Icons are the state names, so they need no legend, and parentheses match
  tmux's own `(attached)` in the `choose-tree` list.
- Icons use the surrounding colours, so they blend into any theme with the
  same contrast as the rest of the status line. In the `choose-tree` list
  they use the normal text colour rather than the grey of the row details.
- States differ by name, so colour is never needed to tell them apart.
- For your own icons, end with the matching `no...` attribute or wrap
  colours in `#[push-default]` ... `#[default]#[pop-default]`, rather than
  `#[default]`, which resets to the status line style.
- Avoid `bold` with a black foreground: many terminals draw bold black as
  grey.

## CLI

The CLI is `scripts/agent-status` in the plugin directory. Hooks generated by
`agent-status hooks` use its absolute path, so putting it on `PATH` is only
needed for running it by hand or from your own scripts:

```sh
mkdir -p ~/.local/bin
ln -s ~/.tmux/plugins/tmux-agent-status/scripts/agent-status ~/.local/bin/agent-status
```

Use a symlink, not a copy: the script finds its helpers and adapters relative
to its real location. Make sure `~/.local/bin` is on your `PATH`.

```
agent-status emit <agent> <event>                  # from agent hooks
agent-status set <state> [--pane P] [--agent A]
agent-status clear [--pane P]
agent-status seen [--pane P]
agent-status refresh
agent-status jump [--client C] [state...]
agent-status list
agent-status check <agent>
agent-status hooks <agent>
```

`--pane` defaults to `$TMUX_PANE`. `jump` switches to a pane in the first of
the given states that has any, cycling through panes on repeated use.

## Limitations

- The pane is identified through `$TMUX_PANE`. Agents that do not pass the
  environment to their hooks (some sandboxes, or an agent running over
  `ssh`) cannot report state.
- If an agent exits without its end event (a crash, `kill -9`), the last
  state stays until the pane closes. Clear it with
  `agent-status clear --pane %N`.
- State is per pane, not per tool call: with parallel tools or subagents, a
  tool finishing while a permission prompt is open switches the pane back to
  `working`.
- The install path must not contain `'`, `"`, `$`, `\`, `` ` `` or `#`.

## Development

```sh
tests/run.sh   # runs against a private tmux server
```

## License

See [LICENSE](LICENSE).
