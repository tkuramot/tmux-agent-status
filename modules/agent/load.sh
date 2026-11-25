# shellcheck shell=bash
# Sourced by pane-status.tmux.

AGENT_CLI="'$CURRENT_DIR/modules/agent/agent-status'"

agent_default() { printf '(%s)' "$1"; }
agent_icon() { icon agent "$1"; }
agent_name() { printf '%s' "$1"; }
agent_tree_icon() { tree_item "$(agent_icon "$1")"; }

# Format yielding `$2 <state>` for the highest-priority state in the
# space-separated list `$1` expands to.
agent_chain() {
	local list="$1" render="$2" st out="" close=""
	for st in $AGENT_STATES; do
		out="$out#{?#{m:*$st*,$list},$("$render" "$st"),"
		close="$close}"
	done
	printf '%s%s' "$out" "$close"
}

# Window state is derived from its panes at draw time, so it never goes stale.
AGENT_PANE="#{$OPT_AGENT_STATE} "
AGENT_WINDOW="#{P:#{$OPT_AGENT_STATE} }"
AGENT_SESSION="#{W:#{P:#{$OPT_AGENT_STATE} }}"

interpolations+=(
	"#{agent_status}" "$(agent_chain "$AGENT_WINDOW" agent_icon)"
	"#{agent_state}" "$(agent_chain "$AGENT_WINDOW" agent_name)"
	"#{agent_pane_status}" "$(agent_chain "$AGENT_PANE" agent_icon)"
	"#{agent_pane_state}" "#{$OPT_AGENT_STATE}"
)
TREE_PANE="$TREE_PANE$(agent_chain "$AGENT_PANE" agent_tree_icon)"
TREE_WINDOW="$TREE_WINDOW$(agent_chain "$AGENT_WINDOW" agent_tree_icon)"
TREE_SESSION="$TREE_SESSION$(agent_chain "$AGENT_SESSION" agent_tree_icon)"

# Under remain-on-exit the dead pane keeps its options.
set_hook pane-died "run-shell -b \"$AGENT_CLI clear --pane #{hook_pane}\""

# Filtered in tmux so ordinary window switches fork nothing.
agent_seen="#{&&:#{==:#{$OPT_AGENT_STATE},done},#{&&:#{session_attached},#{!=:#{@pane-status-agent-auto-seen},off}}}"
for agent_hook in session-window-changed window-pane-changed client-session-changed client-attached; do
	set_hook "$agent_hook" "if-shell -F '$agent_seen' \"run-shell -b \\\"$AGENT_CLI seen --pane #{pane_id}\\\"\""
done
unset agent_hook agent_seen
