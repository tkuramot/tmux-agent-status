#!/usr/bin/env bash
# TPM entry point: sets the plugin's tmux hooks and starts the pull request
# poller. It changes no formats or keys. TPM discards output, so report
# problems with display-message.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$CURRENT_DIR/lib/common.sh"

CLI="$CURRENT_DIR/bin/pane-status"
# Fixed index: reloading replaces our hooks and leaves the user's alone.
HOOK_INDEX=7311

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

set_hook() {
	tmux set-hook -g "$1[$HOOK_INDEX]" "$2"
}

clear_hooks() {
	local hook
	for hook in $({ tmux show-hooks -g; tmux show-hooks -gw; } | awk -v i="[$HOOK_INDEX]" 'index($1, i) { print $1 }'); do
		tmux set-hook -gu "$hook"
	done
}

# A running poller is woken, so a changed interval applies now. A new one runs
# as a tmux job, which tmux kills when the server exits.
start_poller() {
	local pid
	command -v gh >/dev/null 2>&1 || return 0
	if pid="$(poller_pid)"; then
		kill -USR1 "$pid"
	else
		tmux run-shell -b "exec '$CLI' poll >/dev/null 2>&1"
	fi
}

main() {
	if ! tmux_version_at_least 3 8; then
		tmux display-message "tmux-pane-status requires tmux 3.8 or later"
		return 0
	fi
	# The path is embedded in tmux command strings, which expand `#`.
	case "$CURRENT_DIR" in
	*[\'\"\$\\\`#]*)
		tmux display-message "tmux-pane-status: unsupported characters in install path"
		return 0
		;;
	esac
	clear_hooks
	# Under remain-on-exit a dead pane keeps its options.
	set_hook pane-died "run-shell -b \"'$CLI' clear --pane #{hook_pane}\""
	# The poller skips lookups while no client is attached. Without a poller
	# (no gh, interval 0) refresh fails, which is not worth a message.
	set_hook client-attached "run-shell -b \"'$CLI' refresh >/dev/null 2>&1 || :\""
	start_poller
}

main
