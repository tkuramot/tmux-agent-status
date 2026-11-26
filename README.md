# tmux-pane-status

Record the state of what runs in each tmux pane — your AI coding agent and
the pull request of the branch checked out there — as data that your status
line, popups and scripts read.

```
0 zsh 1 api (waiting) 2 web (working) #42 review ✗ 3 docs #40 merged
```

(The window list with the [formats recipe](docs/recipes/formats/formats.tmux).)

The plugin only records state: it changes no formats and binds no keys. What
to show, how to sort it and where to jump are yours to decide, starting from
the [recipes](#recipes). It promises four interfaces, documented below:

1. [Pane options](#pane-options): read them in any tmux format.
2. [`pane-status list`](#list): every pane as JSON, for scripts.
3. [Notifications](#notifications): run your scripts when state changes.
4. [The CLI](#cli): report and acknowledge state, and request a lookup.

## Requirements

- tmux 3.8 or later
- bash 3.2 or later (the macOS system bash works)
- For pull requests: `git` 2.31 or later and `gh` (authenticated). Without
  `gh` the poller does not start.
- `jq`, to install the Claude Code hooks and for some recipes

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

## Quick start

1. Install the plugin as above, and put its CLI on your `PATH` (recipes call
   it as `pane-status`; a symlink, since a copy cannot find its files):

   ```sh
   ln -s ~/.tmux/plugins/tmux-pane-status/bin/pane-status ~/.local/bin/pane-status
   ```

2. Show something. The smallest status line adds each window's active pane to
   the window list:

   ```tmux
   set -g window-status-format '#I #W #{@pane-status_agent_activity} #{?#{@pane-status_pr_number},###{@pane-status_pr_number},}'
   set -g window-status-current-format '#I #W #{@pane-status_agent_activity} #{?#{@pane-status_pr_number},###{@pane-status_pr_number},}'
   ```

   For window-wide state, "done", pane borders and choose-tree, copy
   [formats.tmux](docs/recipes/formats/formats.tmux) instead.

3. For agent state, install your agent's hooks ([Claude Code](#claude-code)).
   Pull requests need no setup.

## Pane options

The plugin writes these pane options. Each is unset when there is nothing to
record.

| Option | Value |
| --- | --- |
| `@pane-status_agent_name` | The agent, e.g. `claude-code`. |
| `@pane-status_agent_activity` | `working`, `waiting`, `idle` or `error`. |
| `@pane-status_agent_since` | When the activity last changed (Unix time). |
| `@pane-status_agent_seen` | `1` if `pane-status seen` was called since the last change, else `0`. |
| `@pane-status_pr_number` | The number of the pull request for the pane's branch. |
| `@pane-status_pr_url` | Its URL. |
| `@pane-status_pr_state` | `open`, `merged` or `closed`. |
| `@pane-status_pr_draft` | `1` for a draft, else `0`. |
| `@pane-status_pr_review` | `approved`, `changes_requested`, `required` (a review is required and none decided it) or `none` (no review required). |
| `@pane-status_pr_checks` | `success`, `failure`, `pending` or `none`: GitHub's own summary of the checks of the last commit. |

Activities:

| Activity | Meaning |
| --- | --- |
| `working` | The agent is busy. |
| `waiting` | The agent needs you (e.g. a permission prompt). |
| `idle` | The agent is waiting for input. |
| `error` | The agent stopped on an error. |

Each field is a separate axis; the plugin does not combine them. "Done" is
`idle` and not seen; a pull request label such as `draft`, `review` or
`changes` combines state, draft and review. The
[formats recipe](docs/recipes/formats/formats.tmux) derives both.

`seen` is reset by every change of activity, so a pane that finishes after you
looked at it while it was waiting is unseen again. An agent's first activity
counts as seen: nothing happened yet that you could have missed. When to call
`seen` is yours to decide; see [auto-seen](docs/recipes/auto-seen).

Options work in any format, including conditionals:

```tmux
set -g window-status-format '#{?#{==:#{@pane-status_agent_activity},waiting},#[bg=red],}#I #W'
```

## list

`pane-status list` prints every pane, with or without state, as JSON:

```json
{"schema_version":1,"panes":[
{"pane":"%3","session":"api","window_index":1,"window_name":"auth","pane_index":0,"title":"✳ Fix login","path":"/src/api",
 "agent":{"name":"claude-code","activity":"idle","since":1764200000,"seen":false},
 "pr":{"number":42,"url":"https://github.com/o/api/pull/42","state":"open","draft":false,"review":"required","checks":"pending"}}
]}
```

`title` is the pane title, or `null` while it is tmux's default, the host
name (full or short). Claude Code sets it to the conversation's topic after a
status glyph that changes, as in `✳ Fix login`. `agent` and `pr` are `null`
when the pane has none; their fields are the pane options above. New fields may be added within a schema version; any other
change bumps it. Scripts should declare the version they were written for,
so they fail loudly rather than silently after an upgrade:

```sh
pane-status list --require-schema 1 | jq ...
```

## Notifications

When state changes, the plugin starts every executable file in
`~/.config/tmux-pane-status/on-change.d/` (`$XDG_CONFIG_HOME` is honoured) in
the background, with:

| Variable | Value |
| --- | --- |
| `PANE_STATUS_SOURCE` | `agent` or `gh`. |
| `PANE_STATUS_PANES` | The changed panes, space-separated, e.g. `%3 %7`. |

- They run after the options are written, with no stdin and output discarded.
- Only real changes notify: an agent reporting the activity it already has
  does not. A poll notifies once for all the panes it changed.
- The order of subscribers is unspecified, and a change may be notified more
  than once.
- Nothing waits for subscribers, agent hooks included. Debounce in the
  subscriber if it is expensive.

## Recipes

[docs/recipes](docs/recipes) holds scripts to copy and edit. They use only the
interfaces above, and the tests run them, so they double as examples. A copy
does not change when you upgrade the plugin: each recipe names the schema it
needs.

| Recipe | What it does | Needs |
| --- | --- | --- |
| [formats](docs/recipes/formats/formats.tmux) | Window list, pane borders and choose-tree, with window-wide state and pull request labels. | |
| [auto-seen](docs/recipes/auto-seen) | Marks a pane seen when you look at it. | |
| [next](docs/recipes/next/next.sh) | Jumps to the most urgent other pane: waiting, error, then done. | `jq` |
| [agents](docs/recipes/agents/agents.sh) | A popup of agent panes grouped by state, with counts and a preview; Enter jumps. | `jq`, `fzf` |
| [refresh-on-idle](docs/recipes/refresh-on-idle/on-change.d/refresh-on-idle) | Looks up pull requests as soon as an agent goes idle. | |

## Agent state

The agent reports changes through its hooks. Only the adapter,
`adapters/<agent>/map`, knows anything about a particular agent.

### Claude Code

Print the hook settings generated from the adapter map:

```sh
pane-status hooks claude-code
```

Merge them into `~/.claude/settings.json` with `jq`. Your other hooks keep
their order, hooks from a previous install (any path) are replaced, and a
symlinked file stays a symlink:

```sh
f=~/.claude/settings.json
[ -f "$f" ] || echo '{}' >"$f"
merge='
  def ours: (.command // "") | test("/bin/pane-status'"'"'? emit ");
  .hooks = ((.hooks // {}) | map_values(map(.hooks |= map(select(ours | not)) | select(.hooks | length > 0)))
    | with_entries(select(.value | length > 0)) as $kept
    | reduce ($new.hooks | keys[]) as $k ($kept; .[$k] = ((.[$k] // []) + $new.hooks[$k])))'
new="$(jq --argjson new "$(pane-status hooks claude-code)" "$merge" "$f")" && printf '%s\n' "$new" >"$f"
```

Event mapping (`adapters/claude-code/map`):

| Claude Code event | Activity |
| --- | --- |
| `SessionStart` (`startup`, `resume`, `clear`) | `idle` |
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure` | `working` |
| `Notification` (`permission_prompt`, `elicitation_dialog`) | `waiting` |
| `Stop` | `idle` |
| `StopFailure` | `error` |
| `SessionEnd` (`logout`, `prompt_input_exit`, `other`) | cleared |

- `SessionStart` with `compact` is not hooked because it can fire mid-turn.
- Interrupting Claude with Esc fires no hook (not even `idle_prompt` later),
  so the pane stays `working` until the next prompt.
- Subagents report through the same pane: while a background subagent runs
  after the main turn has ended, the pane shows `working`.

### Adding another agent

1. Create `~/.config/tmux-pane-status/adapters/<agent>/map` (or
   `adapters/<agent>/map` in this repository to contribute it):

   ```
   # <event>[:<matcher>] <activity|clear> [<from-activity>,...]
   task_started   working
   needs_approval waiting
   task_complete  idle
   idle_timeout   idle     working,waiting
   ```

   - One entry per line; `#` starts a comment line.
   - The optional third field applies the action only when the pane is
     currently in one of those activities.
   - Events are matched exactly. `Event` and `Event:matcher` entries cannot be
     mixed for the same event, since both hooks would fire. Matchers are passed
     to the agent as-is, so `check` cannot detect overlapping patterns such as
     `Bash` and `Bash|Edit`.
   - A user map replaces the built-in map of the same name.

   Validate it with `pane-status check <agent>`: `emit` ignores invalid
   entries silently.

2. Call `pane-status emit <agent> <event>` from the agent's hooks.

`emit` is safe inside any agent's hook: it drains stdin without waiting for it
to close, prints nothing and always exits 0. Outside tmux it does nothing.

Agents without hooks can be wrapped and set activities directly:

```sh
pane-status set working --agent my-agent
my-agent "$@"; rc=$?
if [ "$rc" -eq 0 ]; then pane-status set idle; else pane-status set error; fi
```

## Pull requests

When the plugin loads, it starts one poller as a tmux job, which ends with the
tmux server. Every `@pane-status-gh-interval` seconds while a client is attached,
it finds the branch checked out in each pane and looks up the pull requests
with one `gh` request per repository (worktrees included), however many panes
and branches it has. Attaching a client and `pane-status refresh` make it look
up now.

| Option | Default | Description |
| --- | --- | --- |
| `@pane-status-gh-interval` | `60` | Seconds between lookups. `0` clears pull requests and stops the poller. |

A changed interval applies when the poller next wakes; reloading tmux.conf
wakes it.

A branch's pull request is the newest one whose head is that branch in the
repository itself or in your own fork; same-named branches of other forks,
your organisations' included, are ignored. Merged and closed pull requests are still found for their branch, so a pane
records `merged` until you switch branches. To browse the pull requests of a
pane's repository, open [gh-dash](https://github.com/dlvhdr/gh-dash) in a
popup:

```tmux
bind g display-popup -E -w 90% -h 90% -d '#{pane_current_path}' gh-dash
```

## CLI

```
pane-status emit <agent> <event>                  # from agent hooks
pane-status set <activity> [--pane P] [--agent A]
pane-status clear [--pane P]
pane-status seen [--pane P]
pane-status check <agent>
pane-status hooks <agent>
pane-status refresh
pane-status list [--require-schema N]
```

`--pane` defaults to `$TMUX_PANE`. `set` and `emit` change nothing, not even
the agent name, when the pane already has that activity. `refresh` fails when
no poller runs.

## Limitations

- agent: the pane is identified through `$TMUX_PANE`. Agents that do not pass
  the environment to their hooks (some sandboxes, or an agent running over
  `ssh`) cannot report state.
- agent: if an agent exits without its end event (a crash, `kill -9`), the
  last state stays until the pane closes. Clear it with
  `pane-status clear --pane %N`.
- agent: state is per pane, not per tool call: with parallel tools or
  subagents, a tool finishing while a permission prompt is open switches the
  pane back to `working`.
- gh: a new pane or a switched branch shows up at the next lookup, up to
  `@pane-status-gh-interval` later; call `pane-status refresh` to look up now.
- gh: a failed lookup (offline, not authenticated) clears its panes until the
  next lookup.
- gh: with several remotes, `gh` looks for the pull request in `upstream`,
  `github` or `origin`, in that order, unless `gh repo set-default` says
  otherwise.
- gh: each lookup runs `git` once per pane.
- gh: pull requests are looked up by the local branch name, so a branch that
  pushes to a differently named remote branch finds none.
- The install path must not contain `'`, `"`, `$`, `\`, `` ` `` or `#`.

## Development

```sh
tests/run.sh          # every test file, each against its own private tmux server
tests/run.sh gh list  # only these; files are plugin, agent, list, gh, recipes
```

## License

See [LICENSE](LICENSE).
