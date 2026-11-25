#!/usr/bin/env bash
# TPM entry point. TPM discards output, so report problems with display-message.

shopt -u patsub_replacement 2>/dev/null

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$CURRENT_DIR/scripts/helpers.sh"

# Fixed index: reloading replaces our hooks and leaves the user's alone.
HOOK_INDEX=7311
SCRIPT="'$CURRENT_DIR/scripts/agent-status'"

default_icon() {
	case "$1" in
	waiting) printf '%s' '#[fg=red,bold]!#[default]' ;;
	error) printf '%s' '#[fg=red]x#[default]' ;;
	working) printf '%s' '#[fg=yellow]*#[default]' ;;
	done) printf '%s' '#[fg=green]+#[default]' ;;
	idle) printf '%s' '#[fg=colour244]-#[default]' ;;
	esac
}

# tmux_version_at_least MAJOR MINOR
tmux_version_at_least() {
	local version major minor
	version="$(tmux -V 2>/dev/null)" || return 1
	version="${version#tmux }"
	version="${version#next-}"
	case "$version" in
	master | openbsd*) return 0 ;;
	[0-9]*.[0-9]*) ;;
	*) return 1 ;;
	esac
	major="${version%%.*}"
	minor="${version#*.}"
	minor="${minor%%[!0-9]*}"
	[ "$major" -gt "$1" ] || { [ "$major" -eq "$1" ] && [ "${minor:-0}" -ge "$2" ]; }
}

# Format yielding `$2 <state>` for the highest-priority state in the
# space-separated list `$1` expands to.
state_chain_format() {
	local list="$1" render="$2" st out="" close=""
	for st in $AGENT_STATUS_STATES; do
		out="$out#{?#{m:*$st*,$list},$("$render" "$st"),"
		close="$close}"
	done
	printf '%s%s' "$out" "$close"
}

render_name() { printf '%s' "$1"; }
render_icon() { printf '#{@agent-status-icon-%s}' "$1"; }

# Window state is derived from its panes at draw time, so it never goes stale.
WINDOW_STATES="#{P:#{$OPT_STATE} }"
PANE_STATES="#{$OPT_STATE} "

interpolations=(
	"#{agent_status}" "$(state_chain_format "$WINDOW_STATES" render_icon)"
	"#{agent_state}" "$(state_chain_format "$WINDOW_STATES" render_name)"
	"#{agent_pane_status}" "$(state_chain_format "$PANE_STATES" render_icon)"
	"#{agent_pane_state}" "#{$OPT_STATE}"
	"#{agent_summary}" "#{E:$OPT_SUMMARY}"
)

interpolated_options=(
	status-left
	status-right
	window-status-format
	window-status-current-format
	pane-border-format
)

interpolate() {
	local value="$1" i
	for ((i = 0; i < ${#interpolations[@]}; i += 2)); do
		value="${value//"${interpolations[i]}"/${interpolations[i + 1]}}"
	done
	printf '%s' "$value"
}

update_formats() {
	local option value new
	for option in "${interpolated_options[@]}"; do
		value="$(tmux show-option -gqv "$option")"
		new="$(interpolate "$value")"
		[ "$new" = "$value" ] || tmux set-option -g "$option" "$new"
	done
}

set_default_icons() {
	local st
	for st in $AGENT_STATUS_STATES; do
		tmux set-option -goq "@agent-status-icon-$st" "$(default_icon "$st")"
	done
}

set_hook() {
	tmux set-hook -g "$1[$HOOK_INDEX]" "$2"
}

register_hooks() {
	local hook
	for hook in pane-exited after-kill-pane window-unlinked session-closed; do
		set_hook "$hook" "run-shell -b \"$SCRIPT refresh\""
	done
	# Under remain-on-exit the dead pane keeps its options.
	set_hook pane-died "run-shell -b \"$SCRIPT clear --pane #{hook_pane}\""

	# Filtered in tmux so ordinary window switches fork nothing.
	local cond="#{&&:#{==:#{$OPT_STATE},done},#{&&:#{session_attached},#{!=:#{@agent-status-auto-seen},off}}}"
	for hook in session-window-changed window-pane-changed client-session-changed client-attached; do
		set_hook "$hook" "if-shell -F '$cond' \"run-shell -b \\\"$SCRIPT seen --pane #{pane_id}\\\"\""
	done
}

bind_keys() {
	local key
	key="$(get_tmux_option @agent-status-jump-key '')"
	[ -z "$key" ] || tmux bind-key "$key" run-shell -b "$SCRIPT jump --client '#{client_name}'"
}

main() {
	if ! tmux_version_at_least 3 2; then
		tmux display-message "tmux-agent-status requires tmux 3.2 or later"
		return 0
	fi
	# The path is embedded in tmux command strings and sh single quotes.
	case "$CURRENT_DIR" in
	*[\'\"\$\\\`#]*)
		tmux display-message "tmux-agent-status: unsupported characters in install path"
		return 0
		;;
	esac
	set_default_icons
	update_formats
	register_hooks
	bind_keys
	tmux run-shell -b "$SCRIPT refresh"
}

main
