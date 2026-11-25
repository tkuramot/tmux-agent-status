# shellcheck shell=bash disable=SC2034
# Sourced by pane-status.tmux; it reads the variables set here.

AGENT_CLI="'$CURRENT_DIR/modules/agent/agent-status'"

agent_default() { printf '(%s)' "$1"; }
agent_icon() { icon agent "$1"; }
agent_name() { printf '%s' "$1"; }
agent_tree_icon() { tree_item "$(agent_icon "$1")"; }

# Window state is derived from its panes at draw time, so it never goes stale.
AGENT_PANE="#{$OPT_AGENT_STATE} "
AGENT_WINDOW="#{P:#{$OPT_AGENT_STATE} }"
AGENT_SESSION="#{W:#{P:#{$OPT_AGENT_STATE} }}"

interpolations+=(
	"#{agent_status}" "$(chain "$AGENT_WINDOW" "$AGENT_STATES" agent_icon)"
	"#{agent_state}" "$(chain "$AGENT_WINDOW" "$AGENT_STATES" agent_name)"
	"#{agent_pane_status}" "$(chain "$AGENT_PANE" "$AGENT_STATES" agent_icon)"
	"#{agent_pane_state}" "#{$OPT_AGENT_STATE}"
)
tree_pane="$(chain "$AGENT_PANE" "$AGENT_STATES" agent_tree_icon)"
tree_window="$(chain "$AGENT_WINDOW" "$AGENT_STATES" agent_tree_icon)"
tree_session="$(chain "$AGENT_SESSION" "$AGENT_STATES" agent_tree_icon)"

# Under remain-on-exit the dead pane keeps its options.
set_hook pane-died "run-shell -b \"$AGENT_CLI clear --pane #{hook_pane}\""

# Filtered in tmux so ordinary window switches fork nothing.
agent_seen="#{&&:#{==:#{$OPT_AGENT_STATE},done},#{&&:#{session_attached},#{!=:#{@pane-status-agent-auto-seen},off}}}"
for agent_hook in session-window-changed window-pane-changed client-session-changed client-attached; do
	set_hook "$agent_hook" "if-shell -F '$agent_seen' \"run-shell -b \\\"$AGENT_CLI seen --pane #{pane_id}\\\"\""
done
unset agent_hook agent_seen
