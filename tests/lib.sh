# shellcheck shell=bash disable=SC2034 # the test files use the variables
# Sourced by each test file: starts a private tmux server with one session,
# "test", whose first pane is P1, and provides the assertions.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECIPES="$ROOT/docs/recipes"

# Normalised like the plugin's own path, which pollers are matched by.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pane-status-test.XXXXXX")" && pwd)"
# Run a copy, so that pollers are told apart from one of an installed plugin.
mkdir "$WORK/plugin"
cp -R "$ROOT/bin" "$ROOT/lib" "$ROOT/adapters" "$ROOT/pane-status.tmux" "$WORK/plugin/"
PS="$WORK/plugin/bin/pane-status"
PLUGIN="$WORK/plugin/pane-status.tmux"
SOCKET="$WORK/tmux.sock"
BIN="$WORK/bin"
SUBSCRIBERS="$WORK/config/tmux-pane-status/on-change.d"
export XDG_CONFIG_HOME="$WORK/config" XDG_CACHE_HOME="$WORK/cache" FAKE_GH_DIR="$WORK"
# The fake gh and pane-status (for recipes) come first, also for the server.
export PATH="$BIN:$PATH"
unset TMUX TMUX_PANE

PASS=0
FAIL=0
CONTROL_PID=""

command -v tmux >/dev/null 2>&1 || { echo "tmux not found" >&2; exit 1; }
HAVE_JQ=""
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

t() { tmux -S "$SOCKET" "$@"; }

cleanup() {
	local pid
	exec 3>&- 2>/dev/null
	[ -z "$CONTROL_PID" ] || kill "$CONTROL_PID" 2>/dev/null
	pid="$(t show-option -gqv @pane-status_poller_pid 2>/dev/null)"
	[ -z "$pid" ] || kill "$pid" 2>/dev/null
	t kill-server 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT

assert_eq() { # name expected actual
	if [ "$2" = "$3" ]; then
		PASS=$((PASS + 1))
		printf 'ok   %s\n' "$1"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL %s\n     expected [%s], got [%s]\n' "$1" "$2" "$3"
	fi
}

# For results of background work: hooks, subscribers, the poller.
eventually_eq() { # name expected command...
	local name="$1" expected="$2" actual
	shift 2
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
		actual="$("$@")"
		[ "$actual" = "$expected" ] && break
		sleep 0.1
	done
	assert_eq "$name" "$expected" "$actual"
}

# Prints the summary and fails if any assertion did.
finish() {
	printf '%d passed, %d failed\n' "$PASS" "$FAIL"
	[ "$FAIL" -eq 0 ]
}

opt() { t display-message -p -t "$1" "#{@pane-status_$2}"; }
activity() { opt "$1" agent_activity; }
emit() { TMUX_PANE="$1" "$PS" emit claude-code "$2" </dev/null; }
# New panes start in a given directory, else in $WORK: never in the
# repository the tests run from, which the poller would look up.
new_pane() { t new-window -d -P -F '#{pane_id}' -t test -c "$1"; }
split_pane() { t split-window -d -P -F '#{pane_id}' -t "$1" -c "${2:-$WORK}"; }
# Counts pollers; the poller's subshells share its command line, so processes
# whose parent is a poller are not counted.
pollers() {
	local pids pid n=0
	pids=" $(pgrep -f "$PS poll" | xargs) "
	for pid in $pids; do
		case "$pids" in *" $(ps -o ppid= -p "$pid" | tr -d ' ') "*) ;; *) n=$((n + 1)) ;; esac
	done
	echo "$n"
}
line_count() { if [ -r "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }

# A subscriber that logs each notification as "<source> <panes>".
subscribe_log() {
	mkdir -p "$SUBSCRIBERS"
	# shellcheck disable=SC2016
	printf '#!/bin/sh\necho "$PANE_STATUS_SOURCE $PANE_STATUS_PANES" >>"%s"\n' "$WORK/notified" >"$SUBSCRIBERS/log"
	chmod +x "$SUBSCRIBERS/log"
	: >"$WORK/notified"
}
notified() { cat "$WORK/notified"; }

# Attaches a control client; tmux commands written to fd 3 run as that client.
# Sets CLIENT.
attach_client() {
	mkfifo "$WORK/control.in"
	t -C attach-session -t test <"$WORK/control.in" >/dev/null 2>&1 &
	CONTROL_PID=$!
	exec 3>"$WORK/control.in"
	eventually_eq "control client attached" 1 t display-message -p -t test '#{session_attached}'
	CLIENT="$(t list-clients -F '#{client_name}' | head -n 1)"
}
current_pane() { t display-message -p -c "$CLIENT" '#{pane_id}'; }

mkdir -p "$BIN"
ln -s "$PS" "$BIN/pane-status"
cp "$ROOT/tests/fake/gh" "$BIN/gh"
t -f /dev/null new-session -d -s test -x 120 -y 40 -c "$WORK"
TMUX="$SOCKET,$(t display-message -p '#{pid}'),0"
export TMUX
P1="$(t display-message -p -t test '#{pane_id}')"
