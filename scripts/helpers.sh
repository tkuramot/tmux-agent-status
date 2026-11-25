# shellcheck shell=bash disable=SC2034
# Shared by agent-status.tmux and scripts/agent-status. Keep bash 3.2 compatible.

# Highest priority first.
AGENT_STATUS_STATES="waiting error working done idle"

# Plugin-written options use `_`; user settings use `-`.
OPT_STATE="@agent-status_state"
OPT_AGENT="@agent-status_agent"
OPT_SUMMARY="@agent-status_summary"

# Avoids tmux's window flag characters (* - # ! ~ M Z).
default_icon() {
	case "$1" in
	waiting) printf '%s' '#[fg=red,bold]?#[default]' ;;
	error) printf '%s' '#[fg=red]x#[default]' ;;
	working) printf '%s' '#[fg=yellow]>#[default]' ;;
	done) printf '%s' '#[fg=green]+#[default]' ;;
	idle) printf '%s' '#[fg=colour244].#[default]' ;;
	esac
}

# The user's @agent-status-icon-<state>, else the default. Defaults are not
# written to options, so new defaults apply on reload.
icon_format() {
	local opt="@agent-status-icon-$1" def
	def="$(default_icon "$1")"
	printf '#{?#{%s},#{%s},%s}' "$opt" "$opt" "${def//,/#,}"
}

get_tmux_option() {
	local value
	value="$(tmux show-option -gqv "$1")"
	printf '%s' "${value:-$2}"
}
