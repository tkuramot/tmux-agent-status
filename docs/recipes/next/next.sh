#!/bin/sh
# tmux-pane-status recipe: next
# Schema: list schema 1. Needs: jq, pane-status on PATH.
#
# Jumps to the most urgent other pane: waiting, then error, then done (idle
# and not seen). Bind it, e.g.:
#   bind-key N run-shell -b 'sh ~/.config/tmux/next.sh'

current="$(tmux display-message -p '#{pane_id}')"
pane="$(pane-status list --require-schema 1 | jq -r --arg current "$current" '
	def state: if .agent == null then null
		elif .agent.activity == "idle" and (.agent.seen | not) then "done"
		else .agent.activity end;
	def rank: {"waiting": 0, "error": 1, "done": 2}[state // ""];
	[.panes[] | select(.pane != $current and rank != null)] | sort_by(rank) | .[0].pane // empty')" || exit 1
[ -n "$pane" ] || exit 0
tmux switch-client -t "$pane" \; select-window -t "$pane" \; select-pane -t "$pane"
