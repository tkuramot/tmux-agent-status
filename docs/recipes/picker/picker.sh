#!/bin/sh
# tmux-pane-status recipe: picker
# Schema: list schema 1. Needs: jq, fzf, pane-status on PATH.
#
# Lists panes with an agent or a pull request, most urgent first, with a
# preview of the pane; Enter jumps to it. Bind it, e.g.:
#   bind-key g display-popup -E -w 80% -h 60% 'sh ~/.config/tmux/picker.sh'

pane="$(pane-status list --require-schema 1 | jq -r '
	def state: if .agent == null then ""
		elif .agent.activity == "idle" and (.agent.seen | not) then "done"
		else .agent.activity end;
	def rank: {"waiting": 0, "error": 1, "done": 2, "working": 3, "idle": 4}[state] // 5;
	[.panes[] | select(.agent != null or .pr != null)] | sort_by(rank)[]
	| [.pane, "\(.session):\(.window_name)", state,
		(if .pr then "#\(.pr.number) \(.pr.state)" else "" end)]
	| @tsv' |
	fzf --delimiter '\t' --with-nth 2.. --preview 'tmux capture-pane -ep -t {1}' |
	cut -f 1)" || exit 0
[ -n "$pane" ] || exit 0
tmux switch-client -t "$pane" \; select-window -t "$pane" \; select-pane -t "$pane"
