# shellcheck shell=bash disable=SC2034
# Shared by agent-status.tmux and scripts/agent-status. Keep bash 3.2 compatible.

# Highest priority first.
AGENT_STATUS_STATES="waiting error working done idle"

# Plugin-written options use `_`; user settings use `-`.
OPT_STATE="@agent-status_state"
OPT_AGENT="@agent-status_agent"
OPT_SUMMARY="@agent-status_summary"

get_tmux_option() {
	local value
	value="$(tmux show-option -gqv "$1")"
	printf '%s' "${value:-$2}"
}
