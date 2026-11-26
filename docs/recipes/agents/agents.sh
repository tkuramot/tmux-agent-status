#!/bin/sh
# tmux-pane-status recipe: agents
# Schema: list schema 1. Needs: jq, fzf 0.31 or later, pane-status on PATH.
#
# Lists agent panes grouped by state, most urgent first, with each state's
# count, the pane title (else the window name) and a preview of the pane;
# Enter jumps to it. Bind it, e.g. (-EE keeps the popup open on an error):
#   bind-key a display-popup -EE -w 90% -h 90% 'sh ~/.config/tmux/agents.sh'

command -v fzf >/dev/null 2>&1 || { echo "agents: fzf not found" >&2; exit 1; }
list="$(pane-status list --require-schema 1)" || exit 1

# The first line is the header, e.g. "waiting 1 · error 0 · done 2 ...";
# each other line is "<pane>\t<state> <location> <title> <pull request>".
# Unknown activities sort last.
rows="$(printf '%s\n' "$list" | jq -r '
	def state: if .agent.activity == "idle" and (.agent.seen | not) then "done" else .agent.activity end;
	def states: ["waiting", "error", "done", "working", "idle"];
	def rank: (state as $s | states | index($s)) // (states | length);
	def color: {"waiting": 31, "error": 35, "done": 32, "working": 33}[state] // 90;
	def pad($n): . + ([range($n - length)] | map(" ") | add // "");
	[.panes[] | select(.agent != null) | .location = "\(.session):\(.window_index).\(.pane_index)"] as $agents
	| ([$agents[].location | length] | max // 0) as $width
	| "\t" + ([states[] as $s | "\($s) \([$agents[] | select(state == $s)] | length)"] | join(" · ")),
	($agents | sort_by(rank, .session, .window_index, .pane_index)[]
		| "\(.pane)\t\u001b[\(color)m\(state | pad(7))\u001b[0m  \(.location | pad($width))  \(.title // .window_name)"
			+ (if .pr then "  #\(.pr.number) \(.pr.state)" else "" end))')" || exit 1

# The preview shows the pane with up to HISTORY lines of its history, scrolled
# to the end (scroll up with the mouse or shift-up). capture-pane pads a pane
# with blank lines to its height, which are dropped.
HISTORY=1000
# shellcheck disable=SC2016 # fzf expands the preview command
pane="$(printf '%s\n' "$rows" |
	fzf --ansi --header-lines 1 --delimiter '\t' --with-nth 2 --reverse --preview-window 'down,75%,follow' \
		--preview "tmux capture-pane -ep -S -$HISTORY -t {1}"' | awk "
			{ line[NR] = \$0 } /[^[:space:]]/ { last = NR }
			END { for (i = 1; i <= last; i++) print line[i] }"' |
	cut -f 1)"
[ -n "$pane" ] || exit 0
tmux switch-client -t "$pane" \; select-window -t "$pane" \; select-pane -t "$pane"
