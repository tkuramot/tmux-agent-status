# shellcheck shell=bash disable=SC2034
# Shared by pane-status.tmux and the module scripts. Keep bash 3.2 compatible.

DEFAULT_MODULES="agent gh"

# Plugin-written options use `_`; user settings use `-`.
OPT_TREE_FORMAT="@pane-status_tree_format"

# Highest priority first.
AGENT_STATES="waiting error working done idle"
OPT_AGENT_STATE="@pane-status_agent_state"
OPT_AGENT_NAME="@pane-status_agent_name"

GH_PR_STATES="draft review changes approved merged closed"
GH_CHECKS="failure pending success"
OPT_GH_PR_NUMBER="@pane-status_gh_pr_number"
OPT_GH_PR_STATE="@pane-status_gh_pr_state"
OPT_GH_CHECKS="@pane-status_gh_checks"

# Format for user option $1 if non-empty, else the literal $2. Defaults are
# not written to options, so new defaults apply on reload.
option_format() {
	local rb='}' def="${2//,/#,}"
	printf '#{?#{!=:#{%s},},#{%s},%s}' "$1" "$1" "${def//$rb/#$rb}"
}

get_tmux_option() {
	local value
	value="$(tmux show-option -gqv "$1")"
	printf '%s' "${value:-$2}"
}
