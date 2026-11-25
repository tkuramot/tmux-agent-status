#!/usr/bin/env bash
# Integration tests against a private tmux server.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AS="$ROOT/scripts/agent-status"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-status-test.XXXXXX")"
SOCKET="$WORK/tmux.sock"
export XDG_CONFIG_HOME="$WORK/config"
unset TMUX TMUX_PANE

PASS=0
FAIL=0
CONTROL_PID=""

command -v tmux >/dev/null 2>&1 || { echo "tmux not found" >&2; exit 1; }

t() { tmux -S "$SOCKET" "$@"; }

cleanup() {
	exec 3>&- 2>/dev/null
	[ -z "$CONTROL_PID" ] || kill "$CONTROL_PID" 2>/dev/null
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

# For results of run-shell -b hooks.
eventually_eq() { # name expected command...
	local name="$1" expected="$2" actual
	shift 2
	for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		actual="$("$@")"
		[ "$actual" = "$expected" ] && break
		sleep 0.1
	done
	assert_eq "$name" "$expected" "$actual"
}

render() { t display-message -p -t "$1" "$(t show-option -gqv "$2")"; }
pane_state() { t display-message -p -t "$1" '#{@agent-status_state}'; }
window_state() { render "$1" window-status-format; }
pane_border() { render "$1" pane-border-format; }
summary() { render "$P1" status-right; }
in_pane() { # pane command...
	local pane="$1"
	shift
	TMUX_PANE="$pane" "$AS" "$@"
}
emit() { in_pane "$1" emit claude-code "$2" </dev/null; }

# --- setup ----------------------------------------------------------------

t -f /dev/null new-session -d -s test -x 120 -y 40
SERVER_PID="$(t display-message -p '#{pid}')"
export TMUX="$SOCKET,$SERVER_PID,0"
P1="$(t display-message -p -t test '#{pane_id}')"
W1="$(t display-message -p -t test '#{window_id}')"
P2="$(t split-window -d -P -F '#{pane_id}' -t "$P1")"

t set-option -g @agent-status-icon-waiting A \; set-option -g @agent-status-icon-error E \; \
	set-option -g @agent-status-icon-working R \; set-option -g @agent-status-icon-idle I
t set-hook -g pane-exited 'set-option -g @user-hook ran'
t set-option -g status-right '#{agent_summary}'
t set-option -g window-status-format '#{agent_state}|#{agent_status}'
t set-option -g pane-border-format '#{agent_pane_state}|#{agent_pane_status}'
"$ROOT/agent-status.tmux"
first_load="$(t show-option -gqv window-status-format)"
"$ROOT/agent-status.tmux"

assert_eq "placeholders are interpolated" "" "$(t show-option -gqv window-status-format | grep -F '#{agent_')"
assert_eq "re-loading the plugin is idempotent" "$first_load" "$(t show-option -gqv window-status-format)"
assert_eq "defaults are not written to options" "" "$(t show-option -gqv @agent-status-icon-done)"
assert_eq "user hooks are preserved" 'pane-exited[0] set-option -g @user-hook ran' \
	"$(t show-hooks -g pane-exited | grep -F 'pane-exited[0]')"
assert_eq "no agent renders empty" "|" "$(window_state "$W1")"

# --- emit contract ----------------------------------------------------------

out="$(printf '{"x":1}' | env -u TMUX -u TMUX_PANE "$AS" emit claude-code Stop 2>&1)"
assert_eq "emit outside tmux is a silent no-op" "0:" "$?:$out"
out="$(printf '{"x":1}' | in_pane "$P1" emit no-such-agent Stop 2>&1)"
assert_eq "emit with unknown agent is a silent no-op" "0:" "$?:$out"
out="$(in_pane "$P1" emit ../../etc Stop </dev/null 2>&1)"
assert_eq "emit rejects path-like agent names" "0:" "$?:$out"
out="$(in_pane "$P1" emit claude-code NoSuchEvent </dev/null 2>&1)"
assert_eq "emit with unknown event is a no-op" "0::" "$?:$out:$(pane_state "$P1")"
out="$(in_pane %999 emit claude-code Stop </dev/null 2>&1)"
assert_eq "emit for a missing pane is a silent no-op" "0:" "$?:$out"
mkfifo "$WORK/stdin"
exec 4<>"$WORK/stdin"
start=$(date +%s)
TMUX_PANE="$P1" "$AS" emit claude-code NoSuchEvent <"$WORK/stdin"
assert_eq "emit does not wait for stdin to close" 1 "$(($(date +%s) - start < 4))"
exec 4>&-
# Time emit alone: a pipeline would also wait for the writer.
mkfifo "$WORK/trickle"
(for _ in 1 2 3 4 5 6 7 8 9 10; do printf '{}\n'; sleep 0.5; done) >"$WORK/trickle" 2>/dev/null &
writer=$!
start=$(date +%s)
TMUX_PANE="$P1" "$AS" emit claude-code NoSuchEvent <"$WORK/trickle"
assert_eq "emit stops draining a trickling stdin at its deadline" 1 "$(($(date +%s) - start < 4))"
kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
out="$(env -u HOME -u XDG_CONFIG_HOME TMUX_PANE="$P1" "$AS" emit claude-code NoSuchEvent </dev/null 2>&1)"
assert_eq "emit without HOME is a silent no-op" "0:" "$?:$out"

# --- state transitions ------------------------------------------------------

out="$(printf '{"session_id":"abc"}' | in_pane "$P1" emit claude-code UserPromptSubmit 2>&1)"
assert_eq "emit consumes stdin and prints nothing" "0:" "$?:$out"
assert_eq "pane state is set" working "$(pane_state "$P1")"
assert_eq "agent is recorded" claude-code "$(t display-message -p -t "$P1" '#{@agent-status_agent}')"
assert_eq "pane format renders state and icon" "working|R" "$(pane_border "$P1")"
assert_eq "window derives from its panes" "working|R" "$(window_state "$W1")"
assert_eq "summary counts the pane" R1 "$(summary)"

emit "$P2" Notification:permission_prompt
assert_eq "matcher events map through the adapter" waiting "$(pane_state "$P2")"
assert_eq "window shows the highest-priority state" "waiting|A" "$(window_state "$W1")"
assert_eq "summary lists states in priority order" "A1 R1" "$(summary)"

cond_map="$XDG_CONFIG_HOME/tmux-agent-status/adapters/cond/map"
mkdir -p "$(dirname "$cond_map")"
printf 'Calm idle working,waiting\n' >"$cond_map"
TMUX_PANE="$P2" "$AS" emit cond Calm </dev/null
assert_eq "conditional action applies from a listed state" idle "$(pane_state "$P2")"
emit "$P2" Stop
assert_eq "Stop in a detached session is done" "done" "$(pane_state "$P2")"
TMUX_PANE="$P2" "$AS" emit cond Calm </dev/null
assert_eq "conditional action skips other states" "done" "$(pane_state "$P2")"
rm -rf "$XDG_CONFIG_HOME/tmux-agent-status"
assert_eq "unset icons render the default" "R1 +1" "$(summary)"
t set-option -g @agent-status-icon-done D
assert_eq "icon changes apply without a refresh" "R1 D1" "$(summary)"

"$AS" seen --pane "$P2"
assert_eq "seen ignores detached sessions" "done" "$(pane_state "$P2")"

emit "$P1" 'SessionEnd:logout|prompt_input_exit|other'
assert_eq "SessionEnd clears the pane" "" "$(pane_state "$P1")"
assert_eq "window falls back to the remaining pane" "done|D" "$(window_state "$W1")"
"$AS" clear --pane "$P2"
assert_eq "clearing the last pane clears the window" "|" "$(window_state "$W1")"
assert_eq "summary is empty when nothing counts" "" "$(summary)"

# --- set / validation -------------------------------------------------------

"$AS" set bogus --pane "$P1" 2>/dev/null
assert_eq "set rejects unknown states" 1 "$?"
"$AS" set working --pane %999 2>/dev/null
assert_eq "set rejects missing panes" 1 "$?"
TMUX_PANE="$P1" "$AS" set working --pane "" 2>/dev/null
assert_eq "an explicit empty --pane is an error" "1:" "$?:$(pane_state "$P1")"
"$AS" set error --pane "$P1" --agent my-agent
assert_eq "set works without an adapter" "error:my-agent" \
	"$(pane_state "$P1"):$(t display-message -p -t "$P1" '#{@agent-status_agent}')"
assert_eq "list shows panes with state" "$P1	test:0.0	my-agent	error" "$("$AS" list)"

t set-option -g @agent-status-summary-states 'idle error' \; set-option -g @agent-status-summary-separator '/'
"$AS" set idle --pane "$P2"
assert_eq "summary honours states and separator options" "I1/E1" "$(summary)"
t set-option -gu @agent-status-summary-states \; set-option -gu @agent-status-summary-separator
"$AS" clear --pane "$P1"
"$AS" clear --pane "$P2"

# --- adapters ---------------------------------------------------------------

user_map="$XDG_CONFIG_HOME/tmux-agent-status/adapters/claude-code/map"
mkdir -p "$(dirname "$user_map")"
printf 'Stop error\n' >"$user_map"
emit "$P1" Stop
assert_eq "user adapter overrides the built-in one" error "$(pane_state "$P1")"
printf 'Stop dnoe\nStop done x y\nA:b idle\nA idle\nBad/Event idle\nC clear working\n  # indented comment\n' >"$user_map"
errors="$("$AS" check claude-code 2>&1 >/dev/null)"
assert_eq "check exits non-zero for a bad map" 1 "$("$AS" check claude-code >/dev/null 2>&1; echo $?)"
assert_eq "check reports every problem" 7 "$(printf '%s\n' "$errors" | wc -l | tr -d ' ')"
rm -rf "$XDG_CONFIG_HOME/tmux-agent-status"
"$AS" clear --pane "$P1"

assert_eq "built-in map is valid" 0 "$("$AS" check claude-code >/dev/null; echo $?)"
mkdir -p "$WORK/bin"
ln -s "$AS" "$WORK/bin/agent-status"
assert_eq "the CLI works through a symlink" 0 "$("$WORK/bin/agent-status" check claude-code >/dev/null; echo $?)"
if command -v jq >/dev/null 2>&1; then
	expected="$(grep -v -e '^#' -e '^$' "$ROOT/adapters/claude-code/map" | awk '{ print $1 }')"
	# shellcheck disable=SC2016
	actual="$("$AS" hooks claude-code | jq -r '.hooks | to_entries[] | .key as $e | .value[] |
		(if .matcher then "\($e):\(.matcher)" else $e end) as $k |
		select(.hooks[0].command | endswith(" emit claude-code '\''\($k)'\''")) | $k')"
	assert_eq "hooks cover every map entry with a matching command" "$expected" "$actual"
else
	printf 'skip hooks tests (jq not installed)\n'
fi

# --- pane lifecycle ---------------------------------------------------------

emit "$P2" UserPromptSubmit
t kill-pane -t "$P2"
assert_eq "window updates as soon as a pane closes" "|" "$(window_state "$W1")"
eventually_eq "killing a pane refreshes the summary" "" summary

t set-option -g remain-on-exit on
P4="$(t new-window -d -P -F '#{pane_id}' -t test "tmux -S '$SOCKET' wait-for agent-status-test")"
emit "$P4" UserPromptSubmit
assert_eq "pane under remain-on-exit has state" working "$(pane_state "$P4")"
t wait-for -S agent-status-test
eventually_eq "pane is dead" 1 t display-message -p -t "$P4" '#{pane_dead}'
eventually_eq "a dead pane under remain-on-exit is cleared" "" pane_state "$P4"
t kill-pane -t "$P4"
t set-option -gu remain-on-exit

# --- concurrency ------------------------------------------------------------

P5="$(t split-window -d -P -F '#{pane_id}' -t "$P1")"
P6="$(t split-window -d -P -F '#{pane_id}' -t "$P1")"
for _ in 1 2 3 4 5 6 7 8; do
	for p in "$P1" "$P5" "$P6"; do
		emit "$p" UserPromptSubmit &
		emit "$p" Notification:permission_prompt &
	done
done
wait
"$AS" set working --pane "$P1" & "$AS" set waiting --pane "$P5" & "$AS" set error --pane "$P6" &
wait
assert_eq "summary is consistent after concurrent updates" "A1 E1 R1" "$(summary)"
for p in "$P1" "$P5" "$P6"; do "$AS" clear --pane "$p"; done
t kill-pane -t "$P5" \; kill-pane -t "$P6"

# --- clients: visibility, seen and jump -------------------------------------

P3="$(t new-window -d -P -F '#{pane_id}' -t test)"
P7="$(t split-window -d -P -F '#{pane_id}' -t "$P3")"
mkfifo "$WORK/control.in"
t -C attach-session -t test <"$WORK/control.in" >/dev/null 2>&1 &
CONTROL_PID=$!
exec 3>"$WORK/control.in"
eventually_eq "control client attached" 1 t display-message -p -t test '#{session_attached}'
CLIENT="$(t list-clients -F '#{client_name}' | head -n 1)"
current_pane() { t list-clients -F '#{client_name} #{pane_id}' | awk -v c="$CLIENT" '$1 == c { print $2 }'; }

emit "$P1" Stop
assert_eq "Stop on the visible pane is already seen" idle "$(pane_state "$P1")"
P8="$(t split-window -d -P -F '#{pane_id}' -t "$P1")"
emit "$P8" Stop
assert_eq "Stop on an inactive pane of the visible window is done" "done" "$(pane_state "$P8")"
t select-pane -t "$P8"
eventually_eq "selecting a done pane marks it seen" idle pane_state "$P8"
t kill-pane -t "$P8"
t set-option -g @agent-status-auto-seen off
emit "$P1" Stop
assert_eq "auto-seen off keeps done on the visible pane" "done" "$(pane_state "$P1")"
"$AS" set "done" --pane "$P3"
t select-window -t "$P3"
sleep 0.3
assert_eq "auto-seen off keeps done after switching to it" "done" "$(pane_state "$P3")"
t select-window -t "$W1"
"$AS" clear --pane "$P3"
t set-option -gu @agent-status-auto-seen
"$AS" clear --pane "$P1"

emit "$P3" Stop
emit "$P7" Stop
assert_eq "Stop on a background window is done" done:done "$(pane_state "$P3"):$(pane_state "$P7")"
"$AS" jump --client "$CLIENT"
first="$(current_pane)"
case "$first" in "$P3" | "$P7") r=ok ;; *) r="$first" ;; esac
assert_eq "jump switches to a done pane" ok "$r"
eventually_eq "switching to a done pane marks it seen" idle pane_state "$first"
"$AS" set "done" --pane "$first"
assert_eq "set done on the visible pane is seen" idle "$(pane_state "$first")"

"$AS" set waiting --pane "$P3"
"$AS" set waiting --pane "$P7"
"$AS" jump --client "$CLIENT" waiting
c1="$(current_pane)"
"$AS" jump --client "$CLIENT" waiting
c2="$(current_pane)"
"$AS" jump --client "$CLIENT" waiting
assert_eq "jump cycles through candidates" "1:$c1" "$([ "$c1" != "$c2" ] && echo 1):$(current_pane)"
"$AS" clear --pane "$P3"
"$AS" clear --pane "$P7"

before="$(current_pane)"
"$AS" jump --client "$CLIENT" waiting
assert_eq "jump with no candidate stays put" "$before" "$(current_pane)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
