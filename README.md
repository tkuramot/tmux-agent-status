# tmux-pane-status

Show the state of what runs in each tmux pane — your AI coding agent and the
pull request of the branch checked out there — in the status line, pane
borders and `choose-tree`.

```
0 zsh  1 api (waiting)  2 web (working) #42 review ✗  3 docs #40 merged
```

Scope: per-pane state only. Browsing and acting on pull requests is left to
`gh` and tools such as [gh-dash](https://github.com/dlvhdr/gh-dash).

## Modules

| Module | Shows | Updated by |
| --- | --- | --- |
| `agent` | What the agent in the pane is doing. | The agent's own hooks; nothing is polled. |
| `gh` | The pull request of the pane's branch and its checks. | `gh`, polled on `status-interval` and cached. |

Both are enabled by default. Choose with `@pane-status-modules`:

```tmux
set -g @pane-status-modules 'agent'
```

## Requirements

- tmux 3.8 or later
- bash 3.2 or later (the macOS system bash works)
- `gh`, authenticated, for the `gh` module

## Installation

### With [TPM](https://github.com/tmux-plugins/tpm)

```tmux
set -g @plugin 'tkuramot/tmux-pane-status'
```

Press `prefix + I` to install.

### Manually

```sh
git clone https://github.com/tkuramot/tmux-pane-status ~/.tmux/plugins/tmux-pane-status
```

```tmux
run-shell ~/.tmux/plugins/tmux-pane-status/pane-status.tmux
```

Set the formats that use the placeholders **before** the plugin is loaded
(before `run '~/.tmux/plugins/tpm/tpm'`), and after any theme that sets them.

## Placeholders

```tmux
set -g window-status-format         '#I #W#{?#{agent_state}, #{agent_status},}'
set -g window-status-current-format '#I #W#{?#{agent_state}, #{agent_status},}'
set -g pane-border-status top
set -g pane-border-format ' #{agent_pane_status} #{gh_status} '
```

| Placeholder | Expands to |
| --- | --- |
| `#{agent_status}` | Icon for the window's agent state (the highest of its panes). |
| `#{agent_state}` | That state's name (empty if no agent). |
| `#{agent_pane_status}` | Icon for the pane's agent state. |
| `#{agent_pane_state}` | The pane's agent state name. |
| `#{gh_status}` | `#<number> <state> <checks>` for the pane's pull request, e.g. `#42 review ✗`. |
| `#{gh_state}` | The pull request state name (empty if none). |

In window formats, `gh_*` refers to the window's active pane.

Placeholders are expanded in the **global** values of `status-left`,
`status-right`, `window-status-format`, `window-status-current-format` and
`pane-border-format`; session or window-local values are left alone. State
names work in conditionals:

```tmux
set -g window-status-format '#{?#{==:#{agent_state},waiting},#[bg=red],}#I #W'
```

## States

Each state is shown by its icon, `@pane-status-<module>-icon-<state>`. Unset
or empty means the default.

| Module | State | Meaning | Default icon |
| --- | --- | --- | --- |
| agent | `waiting` | The agent needs you (e.g. a permission prompt). | `(waiting)` |
| agent | `error` | The agent stopped on an error. | `(error)` |
| agent | `working` | The agent is busy. | `(working)` |
| agent | `done` | The agent finished and you have not looked at the pane yet. | `(done)` |
| agent | `idle` | The agent is running and waiting for input. | `(idle)` |
| gh | `draft` | Draft pull request. | `draft` |
| gh | `review` | Open, not yet approved. | `review` |
| gh | `changes` | Changes requested. | `changes` |
| gh | `approved` | Approved. | `approved` |
| gh | `merged` | Merged. | `merged` |
| gh | `closed` | Closed without merging. | `closed` |
| gh | `failure` | A check failed, errored, timed out or was cancelled. | `✗` |
| gh | `pending` | No check failed and some are still running. | `…` |
| gh | `success` | Every check passed or was skipped. | `✓` |

Agent states are listed highest priority first; a window shows the highest
state of its panes. Checks are shown for open pull requests that have any.

```tmux
set -g @pane-status-agent-icon-waiting '#[fg=red]?#[fg=default]'
set -g @pane-status-gh-icon-review 'in review'
```

Icon changes apply on the next redraw. To hide a state, set its icon to `#[]`.

- Agent defaults differ from tmux's window flags (`*`, `-`, `#`, `!`, `~`,
  `M`, `Z`) and use the surrounding colours, so they blend into any theme.
- For your own icons, end with the matching `no...` attribute or wrap colours
  in `#[push-default]` ... `#[default]#[pop-default]`, rather than
  `#[default]`, which resets to the status line style.

## Session and window tree

`prefix s` and `prefix w` (`choose-tree`) show each row's agent state and
pull request after its name. The plugin rebinds these keys only while they
have tmux's default binding; set `@pane-status-choose-tree` to `off` to keep
tmux's own format. For your own `choose-tree` bindings:

```tmux
bind-key s choose-tree -s -F '#{E:@pane-status_tree_format}'
```

## Options

| Option | Default | Description |
| --- | --- | --- |
| `@pane-status-modules` | `agent gh` | Enabled modules. |
| `@pane-status-choose-tree` | `on` | Show states in `prefix s` / `prefix w`. |
| `@pane-status-<module>-icon-<state>` | see [States](#states) | Icon for a state. |
| `@pane-status-agent-auto-seen` | `on` | Turn `done` into `idle` once the pane is viewed in an attached session. |
| `@pane-status-gh-ttl` | `60` | Seconds a pull request lookup is cached. |

## agent module

The agent reports state changes through its hooks. Only the adapter,
`modules/agent/adapters/<agent>/map`, knows anything about a particular agent.

### Claude Code

Print the hook settings generated from the adapter map:

```sh
~/.tmux/plugins/tmux-pane-status/modules/agent/agent-status hooks claude-code
```

Merge them into `~/.claude/settings.json` with `jq`. Your other hooks keep
their order, entries from a previous install (any path) are replaced, and a
symlinked file stays a symlink:

```sh
AS=~/.tmux/plugins/tmux-pane-status/modules/agent/agent-status
f=~/.claude/settings.json
[ -f "$f" ] || echo '{}' >"$f"
merge='
  def ours: any(.hooks[]?; .command | test("/(scripts|modules/agent)/agent-status"));
  .hooks = ((.hooks // {}) | map_values(map(select(ours | not))) as $kept
    | reduce ($new.hooks | keys[]) as $k ($kept; .[$k] = ((.[$k] // []) + $new.hooks[$k])))'
new="$(jq --argjson new "$("$AS" hooks claude-code)" "$merge" "$f")" && printf '%s\n' "$new" >"$f"
```

Event mapping (`modules/agent/adapters/claude-code/map`):

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
  so the pane stays `working` until the next prompt.
- Subagents report through the same pane: while a background subagent runs
  after the main turn has ended, the pane shows `working`.

### Adding another agent

1. Create `~/.config/tmux-pane-status/adapters/<agent>/map` (or
   `modules/agent/adapters/<agent>/map` in this repository to contribute it):

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

   Validate it with `agent-status check <agent>`: `emit` ignores invalid
   entries silently.

2. Call `agent-status emit <agent> <event>` from the agent's hooks.

`emit` is safe inside any agent's hook: it drains stdin without waiting for it
to close, prints nothing and always exits 0. Outside tmux it does nothing.

Agents without hooks can be wrapped and set states directly:

```sh
agent-status set working --agent my-agent
my-agent "$@"; rc=$?
if [ "$rc" -eq 0 ]; then agent-status set done; else agent-status set error; fi
```

### CLI

```
agent-status emit <agent> <event>                  # from agent hooks
agent-status set <state> [--pane P] [--agent A]
agent-status clear [--pane P]
agent-status seen [--pane P]
agent-status list
agent-status check <agent>
agent-status hooks <agent>
```

`--pane` defaults to `$TMUX_PANE`. To run it by hand, symlink it onto your
`PATH` (a copy cannot find its adapters):

```sh
ln -s ~/.tmux/plugins/tmux-pane-status/modules/agent/agent-status ~/.local/bin/agent-status
```

## gh module

`choose-tree` lists every pane, so one job refreshes them all: the plugin
appends `#(…/gh-status tick)`, which prints nothing, to the global
`status-right`. Each tick resolves every pane's repository and branch, reads
the cache, and looks up stale entries with `gh pr view` in the background.
One lookup per repository and branch is made per `@pane-status-gh-ttl`,
however many panes share it.

Merged and closed pull requests are still found for their branch, so a pane
shows `merged` until you switch branches.

To browse pull requests of a pane's repository, open gh-dash in a popup; it
filters to the repository of the directory it starts in:

```tmux
bind g display-popup -E -w 90% -h 90% -d '#{pane_current_path}' gh-dash
```

## Limitations

- agent: the pane is identified through `$TMUX_PANE`. Agents that do not pass
  the environment to their hooks (some sandboxes, or an agent running over
  `ssh`) cannot report state.
- agent: if an agent exits without its end event (a crash, `kill -9`), the
  last state stays until the pane closes. Clear it with
  `agent-status clear --pane %N`.
- agent: state is per pane, not per tool call: with parallel tools or
  subagents, a tool finishing while a permission prompt is open switches the
  pane back to `working`.
- gh: updates stop while no client shows a status line (`status off`), and a
  theme that later overwrites `status-right` drops the refresh job.
- gh: a failed lookup (offline, not authenticated) shows nothing until the
  next lookup.
- The install path must not contain `'`, `"`, `$`, `\`, `` ` `` or `#`.

## Development

```sh
tests/run.sh   # runs against a private tmux server; gh tests need jq and git
```

## License

See [LICENSE](LICENSE).
