# shellcheck shell=bash disable=SC2034
# Shared by agent-status.tmux and scripts/agent-status. Keep bash 3.2 compatible.

# Highest priority first.
AGENT_STATUS_STATES="waiting error working done idle"

# Plugin-written options use `_`; user settings use `-`.
OPT_STATE="@agent-status_state"
OPT_AGENT="@agent-status_agent"
OPT_SUMMARY="@agent-status_summary"
OPT_TREE_FORMAT="@agent-status_tree_format"

# Plain glyphs in the surrounding colours. Avoid window flags (* - # ! ~ M Z),
# and _ or . which the current window's underline hides.
default_icon() {
	case "$1" in
	waiting) printf '?' ;;
	error) printf 'x' ;;
	working) printf '>' ;;
	done) printf '+' ;;
	idle) printf 'o' ;;
	esac
}

# The user's @agent-status-icon-<state> if non-empty, else the default.
# Defaults are not written to options, so new defaults apply on reload.
icon_format() {
	local opt="@agent-status-icon-$1" def rb='}'
	def="$(default_icon "$1")"
	def="${def//,/#,}"
	printf '#{?#{!=:#{%s},},#{%s},%s}' "$opt" "$opt" "${def//$rb/#$rb}"
}

get_tmux_option() {
	local value
	value="$(tmux show-option -gqv "$1")"
	printf '%s' "${value:-$2}"
}
