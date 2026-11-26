# shellcheck shell=bash disable=SC2034
# Shared by pane-status.tmux and bin/pane-status. Keep bash 3.2 compatible.

# Pane options the plugin writes. Their names and values are part of the
# public interface (see README). Plugin-written options use `_`; user
# settings use `-`.
OPT_AGENT_NAME="@pane-status_agent_name"
OPT_AGENT_ACTIVITY="@pane-status_agent_activity"
OPT_AGENT_SINCE="@pane-status_agent_since"
OPT_AGENT_SEEN="@pane-status_agent_seen"
OPT_PR_NUMBER="@pane-status_pr_number"
OPT_PR_URL="@pane-status_pr_url"
OPT_PR_STATE="@pane-status_pr_state"
OPT_PR_DRAFT="@pane-status_pr_draft"
OPT_PR_REVIEW="@pane-status_pr_review"
OPT_PR_CHECKS="@pane-status_pr_checks"
# In the order of the poller's records.
OPT_PRS="$OPT_PR_NUMBER $OPT_PR_URL $OPT_PR_STATE $OPT_PR_DRAFT $OPT_PR_REVIEW $OPT_PR_CHECKS"

# Global, internal.
OPT_POLLER_PID="@pane-status_poller_pid"

US=$'\037'

die() {
	printf 'pane-status: %s\n' "$*" >&2
	exit 1
}

get_tmux_option() {
	local value
	value="$(tmux show-option -gqv "$1")"
	printf '%s' "${value:-$2}"
}

# Prints the user configuration directory; fails without HOME or XDG_CONFIG_HOME.
config_dir() {
	local base="${XDG_CONFIG_HOME:-${HOME:+$HOME/.config}}"
	[ -n "$base" ] && printf '%s/tmux-pane-status' "$base"
}

# is_poller PID: checking the command line keeps a reused PID from being
# mistaken for the poller.
is_poller() {
	case "$1" in '' | *[!0-9]*) return 1 ;; esac
	case "$(ps -p "$1" -o args= 2>/dev/null)" in *"pane-status pr poll"*) return 0 ;; *) return 1 ;; esac
}

# Prints the poller's PID if it is running.
poller_pid() {
	local pid
	pid="$(tmux show-option -gqv "$OPT_POLLER_PID" 2>/dev/null)"
	is_poller "$pid" && printf '%s' "$pid"
}

# write_if PANE CONDITION COMMANDS: runs the tmux COMMANDS if the format
# CONDITION is true for PANE. tmux checks and writes in one command, so
# nothing interleaves. Succeeds if the commands ran.
write_if() {
	[ "$(tmux if-shell -F -t "$1" "$2" "$3 ; display-message -p 1" 2>/dev/null)" = 1 ]
}

# notify SOURCE PANE...: starts every executable in on-change.d in the
# background, so the caller (often an agent hook) never waits for them.
notify() {
	local source="$1" dir f
	shift
	dir="$(config_dir)/on-change.d" || return 0
	[ -d "$dir" ] || return 0
	set +f
	for f in "$dir"/*; do
		[ -f "$f" ] && [ -x "$f" ] || continue
		PANE_STATUS_SOURCE="$source" PANE_STATUS_PANES="$*" "$f" </dev/null >/dev/null 2>&1 &
	done
	set -f
}
