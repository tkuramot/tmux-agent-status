#!/usr/bin/env bash
# Integration tests against a private tmux server.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AS="$ROOT/modules/agent/agent-status"
GS="$ROOT/modules/gh/gh-status"
PLUGIN="$ROOT/pane-status.tmux"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pane-status-test.XXXXXX")"
SOCKET="$WORK/tmux.sock"
export XDG_CONFIG_HOME="$WORK/config" XDG_CACHE_HOME="$WORK/cache"
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
pane_state() { t display-message -p -t "$1" '#{@pane-status_agent_state}'; }
window_state() { render "$1" window-status-format; }
pane_border() { render "$1" pane-border-format; }
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

t set-option -g @pane-status-agent-icon-waiting A \; set-option -g @pane-status-agent-icon-error E \; \
	set-option -g @pane-status-agent-icon-working R \; set-option -g @pane-status-agent-icon-idle I
t set-hook -g pane-exited 'set-option -g @user-hook ran'
t set-option -g window-status-format '#{agent_state}|#{agent_status}'
t set-option -g pane-border-format '#{agent_pane_state}|#{agent_pane_status}'
"$PLUGIN"
first_load="$(t show-option -gqv window-status-format)"
"$PLUGIN"
assert_eq "re-loading the plugin succeeds" 0 "$?"

assert_eq "placeholders are interpolated" "" "$(t show-option -gqv window-status-format | grep -F '#{agent_')"
assert_eq "re-loading the plugin is idempotent" "$first_load" "$(t show-option -gqv window-status-format)"
assert_eq "defaults are not written to options" "" "$(t show-option -gqv @pane-status-agent-icon-done)"
assert_eq "user hooks are preserved" 'pane-exited[0] set-option -g @user-hook ran' \
	"$(t show-hooks -g pane-exited | grep -F 'pane-exited[0]')"
assert_eq "no agent renders empty" "|" "$(window_state "$W1")"
assert_eq "choose-tree keys use the tree format" 2 \
	"$(t list-keys -T prefix | grep -c 'choose-tree -Z[sw] -F "#{E:@pane-status_tree_format}"')"
t bind-key w choose-tree -w \; set-option -g @pane-status-choose-tree off
"$PLUGIN"
assert_eq "turning choose-tree off restores the default" "choose-tree -Zs" \
	"$(t list-keys -T prefix s | awk '{ $1 = $2 = $3 = $4 = ""; print substr($0, 5) }')"
assert_eq "custom choose-tree keys are left alone" "choose-tree -w" \
	"$(t list-keys -T prefix w | awk '{ $1 = $2 = $3 = $4 = ""; print substr($0, 5) }')"
t set-option -gu @pane-status-choose-tree \; bind-key w choose-tree -Zw
"$PLUGIN"

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
assert_eq "agent is recorded" claude-code "$(t display-message -p -t "$P1" '#{@pane-status_agent_name}')"
assert_eq "pane format renders state and icon" "working|R" "$(pane_border "$P1")"
assert_eq "window derives from its panes" "working|R" "$(window_state "$W1")"
case "$(t display-message -p -t "$P1" '#{E:@pane-status_tree_format}')" in *" #[fg=default]R#[fg=themelightgrey]"*) r=ok ;; *) r=no ;; esac
assert_eq "tree format shows the pane state" ok "$r"

emit "$P2" Notification:permission_prompt
assert_eq "matcher events map through the adapter" waiting "$(pane_state "$P2")"
assert_eq "window shows the highest-priority state" "waiting|A" "$(window_state "$W1")"

cond_map="$XDG_CONFIG_HOME/tmux-pane-status/adapters/cond/map"
mkdir -p "$(dirname "$cond_map")"
printf 'Calm idle working,waiting\n' >"$cond_map"
TMUX_PANE="$P2" "$AS" emit cond Calm </dev/null
assert_eq "conditional action applies from a listed state" idle "$(pane_state "$P2")"
emit "$P2" Stop
assert_eq "Stop in a detached session is done" "done" "$(pane_state "$P2")"
TMUX_PANE="$P2" "$AS" emit cond Calm </dev/null
assert_eq "conditional action skips other states" "done" "$(pane_state "$P2")"
rm -rf "$XDG_CONFIG_HOME/tmux-pane-status"
assert_eq "unset icons render the default" "done|(done)" "$(pane_border "$P2")"
t set-option -g @pane-status-agent-icon-done D
assert_eq "icon changes apply without a refresh" "done|D" "$(pane_border "$P2")"

"$AS" seen --pane "$P2"
assert_eq "seen ignores detached sessions" "done" "$(pane_state "$P2")"

emit "$P1" 'SessionEnd:logout|prompt_input_exit|other'
assert_eq "SessionEnd clears the pane" "" "$(pane_state "$P1")"
assert_eq "window falls back to the remaining pane" "done|D" "$(window_state "$W1")"
"$AS" clear --pane "$P2"
assert_eq "clearing the last pane clears the window" "|" "$(window_state "$W1")"

# --- set / validation -------------------------------------------------------

"$AS" set bogus --pane "$P1" 2>/dev/null
assert_eq "set rejects unknown states" 1 "$?"
"$AS" set working --pane %999 2>/dev/null
assert_eq "set rejects missing panes" 1 "$?"
TMUX_PANE="$P1" "$AS" set working --pane "" 2>/dev/null
assert_eq "an explicit empty --pane is an error" "1:" "$?:$(pane_state "$P1")"
"$AS" set error --pane "$P1" --agent my-agent
assert_eq "set works without an adapter" "error:my-agent" \
	"$(pane_state "$P1"):$(t display-message -p -t "$P1" '#{@pane-status_agent_name}')"
assert_eq "list shows panes with state" "$P1	test:0.0	my-agent	error" "$("$AS" list)"

"$AS" clear --pane "$P1"
"$AS" clear --pane "$P2"

# --- adapters ---------------------------------------------------------------

user_map="$XDG_CONFIG_HOME/tmux-pane-status/adapters/claude-code/map"
mkdir -p "$(dirname "$user_map")"
printf 'Stop error\n' >"$user_map"
emit "$P1" Stop
assert_eq "user adapter overrides the built-in one" error "$(pane_state "$P1")"
printf 'Stop dnoe\nStop done x y\nA:b idle\nA idle\nBad/Event idle\nC clear working\n  # indented comment\n' >"$user_map"
errors="$("$AS" check claude-code 2>&1 >/dev/null)"
assert_eq "check exits non-zero for a bad map" 1 "$("$AS" check claude-code >/dev/null 2>&1; echo $?)"
assert_eq "check reports every problem" 7 "$(printf '%s\n' "$errors" | wc -l | tr -d ' ')"
rm -rf "$XDG_CONFIG_HOME/tmux-pane-status"
"$AS" clear --pane "$P1"

assert_eq "built-in map is valid" 0 "$("$AS" check claude-code >/dev/null; echo $?)"
mkdir -p "$WORK/bin"
ln -s "$AS" "$WORK/bin/agent-status"
assert_eq "the CLI works through a symlink" 0 "$("$WORK/bin/agent-status" check claude-code >/dev/null; echo $?)"
if command -v jq >/dev/null 2>&1; then
	expected="$(grep -v -e '^#' -e '^$' "$ROOT/modules/agent/adapters/claude-code/map" | awk '{ print $1 }')"
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

t set-option -g remain-on-exit on
P4="$(t new-window -d -P -F '#{pane_id}' -t test "tmux -S '$SOCKET' wait-for pane-status-test")"
emit "$P4" UserPromptSubmit
assert_eq "pane under remain-on-exit has state" working "$(pane_state "$P4")"
t wait-for -S pane-status-test
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
assert_eq "states are consistent after concurrent updates" "working waiting error" \
	"$(pane_state "$P1") $(pane_state "$P5") $(pane_state "$P6")"
for p in "$P1" "$P5" "$P6"; do "$AS" clear --pane "$p"; done
t kill-pane -t "$P5" \; kill-pane -t "$P6"

# --- clients: visibility and seen -------------------------------------

P3="$(t new-window -d -P -F '#{pane_id}' -t test)"
mkfifo "$WORK/control.in"
t -C attach-session -t test <"$WORK/control.in" >/dev/null 2>&1 &
CONTROL_PID=$!
exec 3>"$WORK/control.in"
eventually_eq "control client attached" 1 t display-message -p -t test '#{session_attached}'
CLIENT="$(t list-clients -F '#{client_name}' | head -n 1)"
current_pane() { t display-message -p -c "$CLIENT" '#{pane_id}'; }

emit "$P1" Stop
assert_eq "Stop on the visible pane is already seen" idle "$(pane_state "$P1")"
P8="$(t split-window -d -P -F '#{pane_id}' -t "$P1")"
emit "$P8" Stop
assert_eq "Stop on an inactive pane of the visible window is done" "done" "$(pane_state "$P8")"
t select-pane -t "$P8"
eventually_eq "selecting a done pane marks it seen" idle pane_state "$P8"
t kill-pane -t "$P8"
t set-option -g @pane-status-agent-auto-seen off
emit "$P1" Stop
assert_eq "auto-seen off keeps done on the visible pane" "done" "$(pane_state "$P1")"
"$AS" set "done" --pane "$P3"
t select-window -t "$P3"
sleep 0.3
assert_eq "auto-seen off keeps done after switching to it" "done" "$(pane_state "$P3")"
t select-window -t "$W1"
"$AS" clear --pane "$P3"
t set-option -gu @pane-status-agent-auto-seen
"$AS" clear --pane "$P1"

"$AS" clear --pane "$P3"

# --- gh ---------------------------------------------------------------------

# Fake gh: answers from $WORK/prs/<repo>.json through the plugin's own --jq
# filter and logs each call.
gh_tests() {
	local bin="$WORK/ghbin" prs="$WORK/prs" repo pa pb pc pd pe before r start
	mkdir -p "$bin" "$prs"
	cat >"$bin/gh" <<EOF
#!/bin/sh
basename "\$PWD" >>"$WORK/gh.log"
[ ! -r "$WORK/gh.sleep" ] || sleep "\$(cat "$WORK/gh.sleep")"
while [ "\$#" -gt 0 ] && [ "\$1" != --jq ]; do shift; done
f="$prs/\$(basename "\$PWD").json"
[ -r "\$f" ] || { echo "no pull requests found" >&2; exit 1; }
exec jq -r "\$2" "\$f"
EOF
	chmod +x "$bin/gh"
	for repo in ra rb rc; do
		git init -q "$WORK/$repo"
		git -C "$WORK/$repo" checkout -q -b feature
		git -C "$WORK/$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
	done
	git -C "$WORK/rc" checkout -q --detach
	printf '%s' '{"number":7,"state":"OPEN","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[
		{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
		{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"},
		{"__typename":"StatusContext","state":"PENDING"}]}' >"$prs/ra.json"
	printf '%s' '{"number":8,"state":"MERGED","isDraft":false,"reviewDecision":"APPROVED","statusCheckRollup":[
		{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]}' >"$prs/rb.json"
	printf '%s' '{"number":9,"state":"OPEN","isDraft":true,"reviewDecision":"","statusCheckRollup":[]}' >"$prs/rc.json"

	gh_pane() { t display-message -p -t "$1" "$(t show-option -gqv pane-border-format)"; }
	tick() { PATH="$bin:$PATH" "$GS" tick; }
	calls() { if [ -r "$WORK/gh.log" ]; then wc -l <"$WORK/gh.log" | tr -d ' '; else echo 0; fi; }

	GW="$(t new-window -d -P -F '#{window_id}' -t test -c "$WORK/ra")"
	pa="$(t display-message -p -t "$GW" '#{pane_id}')"
	pb="$(t split-window -d -P -F '#{pane_id}' -t "$pa" -c "$WORK/rb")"
	pc="$(t split-window -d -P -F '#{pane_id}' -t "$pa" -c "$WORK/rc")"
	pd="$(t split-window -d -P -F '#{pane_id}' -t "$pa" -c "$WORK")"
	pe="$(t split-window -d -P -F '#{pane_id}' -t "$pa" -c "$WORK/ra")"
	t set-option -g pane-border-format '#{gh_status}|#{gh_state}' \; set-option -g status-right 'right'
	"$PLUGIN"
	"$PLUGIN"
	assert_eq "the refresh job is added to status-right once" "right#('$GS' tick)" "$(t show-option -gqv status-right)"

	tick
	eventually_eq "failing checks win over pending ones" "#7 review ✗|review" gh_pane "$pa"
	eventually_eq "panes on the same branch share the result" "#7 review ✗|review" gh_pane "$pe"
	assert_eq "one lookup per repository and branch" 1 "$(grep -c "^ra\$" "$WORK/gh.log")"
	eventually_eq "merged hides checks" "#8 merged|merged" gh_pane "$pb"
	assert_eq "detached HEAD shows nothing" "|" "$(gh_pane "$pc")"
	assert_eq "a directory outside a repository shows nothing" "|" "$(gh_pane "$pd")"
	case "$(t display-message -p -t "$pa" '#{E:@pane-status_tree_format}')" in *"#[fg=default]#7 review ✗#[fg=themelightgrey]"*) r=ok ;; *) r=no ;; esac
	assert_eq "tree format shows the pull request" ok "$r"

	before="$(calls)"
	tick
	sleep 0.5
	assert_eq "a fresh cache does not call gh" "$before" "$(calls)"
	t set-option -g @pane-status-gh-icon-review R \; set-option -g @pane-status-gh-icon-failure F
	assert_eq "icon changes apply without a refresh" "#7 R F|review" "$(gh_pane "$pa")"
	t set-option -gu @pane-status-gh-icon-review \; set-option -gu @pane-status-gh-icon-failure

	git -C "$WORK/rc" checkout -q feature
	rm "$prs/rb.json"
	t set-option -g @pane-status-gh-ttl 0
	tick
	eventually_eq "a draft without checks shows no icon" "#9 draft|draft" gh_pane "$pc"
	eventually_eq "a pane whose pull request is gone is cleared" "|" gh_pane "$pb"

	echo 3 >"$WORK/gh.sleep"
	start=$(date +%s)
	tick | cat
	assert_eq "tick does not wait for lookups" 1 "$(($(date +%s) - start < 2))"
	rm "$WORK/gh.sleep"

	t set-option -g remain-on-exit on
	pd="$(t new-window -d -P -F '#{pane_id}' -t test -c "$WORK/rb" true)"
	eventually_eq "pane is dead" 1 t display-message -p -t "$pd" '#{pane_dead}'
	(cd "$WORK/ra" && tick)
	sleep 0.5
	assert_eq "a dead pane is not resolved from the job's directory" "|" "$(gh_pane "$pd")"
	t kill-pane -t "$pd" \; set-option -gu remain-on-exit

	t set-option -g @pane-status-modules agent
	rm -f "$WORK/gh.log"
	tick
	sleep 0.5
	assert_eq "a disabled module makes no lookups" 0 "$(calls)"
	assert_eq "a disabled module clears its state" "|" "$(gh_pane "$pa")"
	t set-option -gu @pane-status-gh-ttl \; set-option -gu @pane-status-modules
	t kill-window -t "$GW"
}
if command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
	gh_tests
else
	printf 'skip gh tests (jq or git not installed)\n'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
