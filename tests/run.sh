#!/usr/bin/env bash
# Integration tests against a private tmux server.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PS="$ROOT/bin/pane-status"
PLUGIN="$ROOT/pane-status.tmux"
RECIPES="$ROOT/docs/recipes"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pane-status-test.XXXXXX")"
SOCKET="$WORK/tmux.sock"
BIN="$WORK/bin"
SUBSCRIBERS="$WORK/config/tmux-pane-status/on-change.d"
export XDG_CONFIG_HOME="$WORK/config" XDG_CACHE_HOME="$WORK/cache"
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

opt() { t display-message -p -t "$1" "#{@pane-status_$2}"; }
activity() { opt "$1" agent_activity; }
emit() { TMUX_PANE="$1" "$PS" emit claude-code "$2" </dev/null; }

# A subscriber that logs each notification as "<source> <panes>".
subscribe_log() {
	mkdir -p "$SUBSCRIBERS"
	# shellcheck disable=SC2016
	printf '#!/bin/sh\necho "$PANE_STATUS_SOURCE $PANE_STATUS_PANES" >>"%s"\n' "$WORK/notified" >"$SUBSCRIBERS/log"
	chmod +x "$SUBSCRIBERS/log"
	: >"$WORK/notified"
}
notified() { cat "$WORK/notified"; }

# --- setup ----------------------------------------------------------------

mkdir -p "$BIN"
ln -s "$PS" "$BIN/pane-status"
t -f /dev/null new-session -d -s test -x 120 -y 40 -c "$WORK"
SERVER_PID="$(t display-message -p '#{pid}')"
export TMUX="$SOCKET,$SERVER_PID,0"
P1="$(t display-message -p -t test '#{pane_id}')"
P2="$(t split-window -d -P -F '#{pane_id}' -t "$P1")"

# --- plugin load ------------------------------------------------------------

t set-hook -g pane-exited 'set-option -g @user-hook ran'
t set-option -g window-status-format 'mine' \; set-option -g status-right 'right'
"$PLUGIN"
"$PLUGIN"
assert_eq "re-loading the plugin succeeds" 0 "$?"
assert_eq "formats are left alone" "mine:right" \
	"$(t show-option -gqv window-status-format):$(t show-option -gqv status-right)"
assert_eq "choose-tree keys are left alone" "choose-tree -Zs" \
	"$(t list-keys -T prefix s | awk '{ $1 = $2 = $3 = $4 = ""; print substr($0, 5) }')"
assert_eq "user hooks are preserved" 'pane-exited[0] set-option -g @user-hook ran' \
	"$(t show-hooks -g pane-exited | grep -F 'pane-exited[0]')"
t set-hook -g 'pane-exited[7311]' 'set-option -g @stale-hook ran'
"$PLUGIN"
assert_eq "stale hooks of ours are removed" "" "$(t show-hooks -g pane-exited | grep -F '[7311]')"

# --- emit contract ----------------------------------------------------------

out="$(printf '{"x":1}' | env -u TMUX -u TMUX_PANE "$PS" emit claude-code Stop 2>&1)"
assert_eq "emit outside tmux is a silent no-op" "0:" "$?:$out"
out="$(printf '{"x":1}' | TMUX_PANE="$P1" "$PS" emit no-such-agent Stop 2>&1)"
assert_eq "emit with unknown agent is a silent no-op" "0:" "$?:$out"
out="$(TMUX_PANE="$P1" "$PS" emit ../../etc Stop </dev/null 2>&1)"
assert_eq "emit rejects path-like agent names" "0:" "$?:$out"
out="$(TMUX_PANE="$P1" "$PS" emit claude-code NoSuchEvent </dev/null 2>&1)"
assert_eq "emit with unknown event is a no-op" "0::" "$?:$out:$(activity "$P1")"
out="$(TMUX_PANE=%999 "$PS" emit claude-code Stop </dev/null 2>&1)"
assert_eq "emit for a missing pane is a silent no-op" "0:" "$?:$out"
mkfifo "$WORK/stdin"
exec 4<>"$WORK/stdin"
start=$(date +%s)
TMUX_PANE="$P1" "$PS" emit claude-code NoSuchEvent <"$WORK/stdin"
assert_eq "emit does not wait for stdin to close" 1 "$(($(date +%s) - start < 4))"
exec 4>&-
# Time emit alone: a pipeline would also wait for the writer.
mkfifo "$WORK/trickle"
(for _ in 1 2 3 4 5 6 7 8 9 10; do printf '{}\n'; sleep 0.5; done) >"$WORK/trickle" 2>/dev/null &
writer=$!
start=$(date +%s)
TMUX_PANE="$P1" "$PS" emit claude-code NoSuchEvent <"$WORK/trickle"
assert_eq "emit stops draining a trickling stdin at its deadline" 1 "$(($(date +%s) - start < 4))"
kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
out="$(env -u HOME -u XDG_CONFIG_HOME TMUX_PANE="$P1" "$PS" emit claude-code NoSuchEvent </dev/null 2>&1)"
assert_eq "emit without HOME is a silent no-op" "0:" "$?:$out"

# --- activity, since and seen ------------------------------------------------

out="$(printf '{"session_id":"abc"}' | TMUX_PANE="$P1" "$PS" emit claude-code SessionStart:startup 2>&1)"
assert_eq "emit consumes stdin and prints nothing" "0:" "$?:$out"
assert_eq "the first activity is recorded as seen" "idle:1:claude-code" \
	"$(activity "$P1"):$(opt "$P1" agent_seen):$(opt "$P1" agent_name)"
emit "$P1" UserPromptSubmit
assert_eq "a change of activity is unseen" "working:0" "$(activity "$P1"):$(opt "$P1" agent_seen)"
case "$(opt "$P1" agent_since)" in '' | *[!0-9]*) r=no ;; *) r=ok ;; esac
assert_eq "since is a timestamp" ok "$r"
t set-option -p -t "$P1" @pane-status_agent_since 1 \; set-option -p -t "$P1" @pane-status_agent_seen 1
emit "$P1" PreToolUse
assert_eq "a repeated activity changes nothing" "working:1:1" \
	"$(activity "$P1"):$(opt "$P1" agent_since):$(opt "$P1" agent_seen)"
emit "$P1" Stop
"$PS" seen --pane "$P1"
assert_eq "seen marks the activity seen" "idle:1" "$(activity "$P1"):$(opt "$P1" agent_seen)"
emit "$P2" Notification:permission_prompt
assert_eq "matcher events map through the adapter" waiting "$(activity "$P2")"

cond_map="$XDG_CONFIG_HOME/tmux-pane-status/adapters/cond/map"
mkdir -p "$(dirname "$cond_map")"
printf 'Calm idle working,waiting\n' >"$cond_map"
TMUX_PANE="$P2" "$PS" emit cond Calm </dev/null
assert_eq "a conditional action applies from a listed activity" idle "$(activity "$P2")"
"$PS" set error --pane "$P2"
TMUX_PANE="$P2" "$PS" emit cond Calm </dev/null
assert_eq "a conditional action skips other activities" error "$(activity "$P2")"
rm -rf "$XDG_CONFIG_HOME/tmux-pane-status"

emit "$P1" 'SessionEnd:logout|prompt_input_exit|other'
assert_eq "SessionEnd clears every agent option" ":::" \
	"$(activity "$P1"):$(opt "$P1" agent_since):$(opt "$P1" agent_seen):$(opt "$P1" agent_name)"
"$PS" clear --pane "$P2"

# --- notifications ------------------------------------------------------------

subscribe_log
emit "$P1" UserPromptSubmit
eventually_eq "a change notifies its pane" "agent $P1" notified
: >"$WORK/notified"
emit "$P1" PreToolUse
emit "$P1" Stop
"$PS" seen --pane "$P1"
"$PS" seen --pane "$P1"
"$PS" clear --pane "$P1"
"$PS" clear --pane "$P1"
eventually_eq "changes, seen and clear notify; repeats do not" 3 sh -c "wc -l <'$WORK/notified' | tr -d ' '"
printf '#!/bin/sh\nsleep 5\n' >"$SUBSCRIBERS/slow"
chmod +x "$SUBSCRIBERS/slow"
start=$(date +%s)
emit "$P1" UserPromptSubmit
assert_eq "emit does not wait for subscribers" 1 "$(($(date +%s) - start < 2))"
rm -rf "$SUBSCRIBERS"
"$PS" clear --pane "$P1"

# --- set / validation -------------------------------------------------------

"$PS" set bogus --pane "$P1" 2>/dev/null
assert_eq "set rejects unknown activities" 1 "$?"
"$PS" set "done" --pane "$P1" 2>/dev/null
assert_eq "done is not an activity" 1 "$?"
"$PS" set working --pane %999 2>/dev/null
assert_eq "set rejects missing panes" 1 "$?"
TMUX_PANE="$P1" "$PS" set working --pane "" 2>/dev/null
assert_eq "an explicit empty --pane is an error" "1:" "$?:$(activity "$P1")"
"$PS" set error --pane "$P1" --agent my-agent
assert_eq "set works without an adapter" "error:my-agent" "$(activity "$P1"):$(opt "$P1" agent_name)"

# --- list -------------------------------------------------------------------

"$PS" list --require-schema 2 >/dev/null 2>&1
assert_eq "list fails for another schema" 1 "$?"
if [ -n "$HAVE_JQ" ]; then
	t rename-window -t "$P1" 'say "hi"'
	# shellcheck disable=SC2016
	assert_eq "list reports panes as documented" \
		"1|$P1|test|0|say \"hi\"|my-agent|error|true|null|$P2|null" \
		"$("$PS" list --require-schema 1 | jq -r --arg p1 "$P1" --arg p2 "$P2" '
			(.panes[] | select(.pane == $p1)) as $a | (.panes[] | select(.pane == $p2)) as $b
			| [.schema_version, $a.pane, $a.session, $a.window_index, $a.window_name,
				$a.agent.name, $a.agent.activity, $a.agent.seen, ($a.pr | tojson),
				$b.pane, ($b.agent | tojson)] | join("|")')"
	t link-window -s test:0 -t test:9
	assert_eq "list shows a linked pane once" 1 "$("$PS" list | jq --arg p "$P1" '[.panes[] | select(.pane == $p)] | length')"
	t unlink-window -t test:9 \; rename-window -t "$P1" main
	odd="$(cd -P "$WORK" && pwd)/esc$(printf '\033')\\dir"
	mkdir -p "$odd" "$WORK/new
line"
	po="$(t new-window -d -P -F '#{pane_id}' -t test -c "$odd")"
	pn="$(t new-window -d -P -F '#{pane_id}' -t test -c "$WORK/new
line")"
	assert_eq "list escapes control characters" "$odd" "$("$PS" list | jq -r --arg p "$po" '.panes[] | select(.pane == $p) | .path')"
	assert_eq "list keeps a path with a newline from splitting its record" \
		"$(t list-panes -a -F '#{pane_id}' | sort -u | xargs)" "$("$PS" list | jq -r '.panes[].pane' | sort | xargs)"
	t kill-window -t "$po" \; kill-window -t "$pn"
else
	printf 'skip list tests (jq not installed)\n'
fi
"$PS" clear --pane "$P1"

# --- adapters ---------------------------------------------------------------

user_map="$XDG_CONFIG_HOME/tmux-pane-status/adapters/claude-code/map"
mkdir -p "$(dirname "$user_map")"
printf 'Stop error\n' >"$user_map"
emit "$P1" Stop
assert_eq "user adapter overrides the built-in one" error "$(activity "$P1")"
printf 'Stop done\nStop idle x y\nA:b idle\nA idle\nBad/Event idle\nC clear working\n  # indented comment\n' >"$user_map"
errors="$("$PS" check claude-code 2>&1 >/dev/null)"
assert_eq "check exits non-zero for a bad map" 1 "$("$PS" check claude-code >/dev/null 2>&1; echo $?)"
assert_eq "check reports every problem" 7 "$(printf '%s\n' "$errors" | wc -l | tr -d ' ')"
rm -rf "$XDG_CONFIG_HOME/tmux-pane-status"
"$PS" clear --pane "$P1"

assert_eq "built-in map is valid" 0 "$("$PS" check claude-code >/dev/null; echo $?)"
assert_eq "the CLI works through a symlink" 0 "$("$BIN/pane-status" check claude-code >/dev/null; echo $?)"
if [ -n "$HAVE_JQ" ]; then
	expected="$(grep -v -e '^#' -e '^$' "$ROOT/adapters/claude-code/map" | awk '{ print $1 }')"
	# shellcheck disable=SC2016
	actual="$("$PS" hooks claude-code | jq -r '.hooks | to_entries[] | .key as $e | .value[] |
		(if .matcher then "\($e):\(.matcher)" else $e end) as $k |
		select(.hooks[0].command | endswith(" emit claude-code '\''\($k)'\''")) | $k')"
	assert_eq "hooks cover every map entry with a matching command" "$expected" "$actual"
fi

# --- pane lifecycle ---------------------------------------------------------

t set-option -g remain-on-exit on
P4="$(t new-window -d -P -F '#{pane_id}' -t test "tmux -S '$SOCKET' wait-for pane-status-test")"
emit "$P4" UserPromptSubmit
assert_eq "pane under remain-on-exit has state" working "$(activity "$P4")"
t wait-for -S pane-status-test
eventually_eq "pane is dead" 1 t display-message -p -t "$P4" '#{pane_dead}'
eventually_eq "a dead pane under remain-on-exit is cleared" "" activity "$P4"
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
"$PS" set working --pane "$P1" & "$PS" set waiting --pane "$P5" & "$PS" set error --pane "$P6" &
wait
assert_eq "activities are consistent after concurrent updates" "working waiting error" \
	"$(activity "$P1") $(activity "$P5") $(activity "$P6")"
for p in "$P1" "$P5" "$P6"; do "$PS" clear --pane "$p"; done
t kill-pane -t "$P5" \; kill-pane -t "$P6" \; kill-pane -t "$P2"

# --- clients ------------------------------------------------------------------

P3="$(t new-window -d -P -F '#{pane_id}' -t test -c "$WORK")"
mkfifo "$WORK/control.in"
t -C attach-session -t test <"$WORK/control.in" >/dev/null 2>&1 &
CONTROL_PID=$!
exec 3>"$WORK/control.in"
eventually_eq "control client attached" 1 t display-message -p -t test '#{session_attached}'
CLIENT="$(t list-clients -F '#{client_name}' | head -n 1)"
current_pane() { t display-message -p -c "$CLIENT" '#{pane_id}'; }

# --- gh -----------------------------------------------------------------------

# Fake gh: answers from $WORK/prs/<repo>.json, a GraphQL response, through the
# plugin's own --jq filter, and logs "<repo> <branches>" for each call.
gh_tests() {
	local prs="$WORK/prs" repo pa pb pc pd pe pw before
	mkdir -p "$prs"
	cat >"$BIN/gh" <<EOF
#!/bin/sh
[ "\$1" != auth ] || [ "\$4" = ghe.test ] || exit 1
[ "\$1" != auth ] || exit 0
case " \$* " in *" --hostname ghe.test "*) echo "\$(basename "\$PWD")" >>"$WORK/gh.hosts" ;; esac
branches=0
for arg; do case "\$arg" in b[0-9]*=*) branches=\$((branches + 1)) ;; esac; done
echo "\$(basename "\$PWD") \$branches" >>"$WORK/gh.log"
while [ "\$#" -gt 0 ] && [ "\$1" != --jq ]; do shift; done
f="$prs/\$(basename "\$PWD").json"
[ -r "\$f" ] || { echo "GraphQL: Could not resolve to a Repository" >&2; exit 1; }
exec jq -r "\$2" "\$f"
EOF
	chmod +x "$BIN/gh"
	for repo in ra rb rc; do
		git init -q "$WORK/$repo"
		git -C "$WORK/$repo" checkout -q -b feature
		git -C "$WORK/$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
	done
	git -C "$WORK/ra" worktree add -q -b other "$WORK/ra-other"
	git -C "$WORK/rc" checkout -q --detach
	git -C "$WORK/ra" remote add origin https://ghe.test/o/ra.git
	git -C "$WORK/rb" remote add origin git@github-work:o/rb.git
	pr() { # number state draft review checks [head-owner]: a pull request, from a fork if head-owner is given
		printf '{"number":%s,"url":"https://github.com/o/r/pull/%s","state":"%s","isDraft":%s,"reviewDecision":%s,
			"isCrossRepository":%s,"headRepositoryOwner":{"login":"%s"},
			"commits":{"nodes":[{"commit":{"statusCheckRollup":%s}}]}}' \
			"$1" "$1" "$2" "$3" "$4" "$([ -n "${6:-}" ] && echo true || echo false)" "${6:-o}" "$5"
	}
	response() { # alias=pull-requests...
		local a sep=""
		printf '{"data":{"viewer":{"login":"me"},"repository":{'
		for a; do printf '%s"%s":{"nodes":[%s]}' "$sep" "${a%%=*}" "${a#*=}"; sep=","; done
		printf '}}}'
	}
	response "b0=$(pr 99 CLOSED false null null stranger),$(pr 7 OPEN false '"CHANGES_REQUESTED"' '{"state":"ERROR"}')" \
		"b1=$(pr 70 OPEN true null null me)" >"$prs/ra.json"
	cp "$prs/ra.json" "$prs/ra-other.json"
	response "b0=$(pr 8 MERGED false '"APPROVED"' '{"state":"SUCCESS"}')" >"$prs/rb.json"

	record() { t display-message -p -t "$1" '#{@pane-status_pr_number} #{@pane-status_pr_state} #{@pane-status_pr_draft} #{@pane-status_pr_review} #{@pane-status_pr_checks}'; }
	calls() { if [ -r "$WORK/gh.log" ]; then cat "$WORK/gh.log"; fi; }

	new_pane() { t new-window -d -P -F '#{pane_id}' -t test -c "$1"; }
	pa="$(new_pane "$WORK/ra")"
	pe="$(new_pane "$WORK/ra")"
	pw="$(new_pane "$WORK/ra-other")"
	pb="$(new_pane "$WORK/rb")"
	pc="$(new_pane "$WORK/rc")"
	pd="$(new_pane "$WORK")"

	t set-option -g @pane-status-gh-interval 3600
	subscribe_log
	"$PLUGIN" & load=$!
	"$PLUGIN"
	wait "$load"
	eventually_eq "concurrent loads leave one poller" 1 sh -c "ps -A -o args= | grep -c '[p]ane-status poll'"
	eventually_eq "values are renamed, not combined; other forks are ignored" "7 open 0 changes_requested failure" record "$pa"
	eventually_eq "panes on the same branch share the result" "7 open 0 changes_requested failure" record "$pe"
	assert_eq "a worktree is the same repository; your fork counts" "70 open 1 none none" "$(record "$pw")"
	assert_eq "one lookup per repository, for all its branches" "ra 2
rb 1" "$(calls | sort)"
	assert_eq "lookups go to the remote's host if gh is logged in to it" ra "$(sort -u "$WORK/gh.hosts")"
	assert_eq "merged pull requests keep their checks" "8 merged 0 approved success" "$(record "$pb")"
	assert_eq "the url is recorded" "https://github.com/o/r/pull/8" "$(opt "$pb" pr_url)"
	assert_eq "detached HEAD has no pull request" "    " "$(record "$pc")"
	assert_eq "a directory outside a repository has none" "    " "$(record "$pd")"
	eventually_eq "one notification for all changed panes" 1 sh -c "wc -l <'$WORK/notified' | tr -d ' '"
	assert_eq "it names its source and the changed panes" "gh $(printf '%s\n' "$pa" "$pe" "$pw" "$pb" | sort | xargs)" \
		"$(cut -d ' ' -f 1 "$WORK/notified") $(cut -d ' ' -f 2- "$WORK/notified" | tr ' ' '\n' | sort | xargs)"
	if [ -n "$HAVE_JQ" ]; then
		assert_eq "list reports the pull request" '{"number":8,"url":"https://github.com/o/r/pull/8","state":"merged","draft":false,"review":"approved","checks":"success"}' \
			"$("$PS" list | jq -c --arg p "$pb" '.panes[] | select(.pane == $p) | .pr')"
	fi

	: >"$WORK/notified"
	rm -f "$WORK/gh.log"
	"$PS" refresh
	eventually_eq "a refresh looks up again" 2 sh -c "wc -l 2>/dev/null <'$WORK/gh.log' | tr -d ' '"
	sleep 0.3
	assert_eq "unchanged pull requests notify nothing" "" "$(notified)"

	git -C "$WORK/rc" checkout -q feature
	rm "$prs/rb.json"
	"$PS" refresh
	eventually_eq "a failed lookup clears its panes" "    " record "$pb"
	assert_eq "a branch without a pull request has none" "    " "$(record "$pc")"

	t set-option -g remain-on-exit on
	before="$(t new-window -d -P -F '#{pane_id}' -t test -c "$WORK/ra" true)"
	eventually_eq "pane is dead" 1 t display-message -p -t "$before" '#{pane_dead}'
	"$PS" refresh
	sleep 0.5
	assert_eq "a dead pane is not looked up" "    " "$(record "$before")"
	t kill-pane -t "$before" \; set-option -gu remain-on-exit

	cp "$RECIPES/refresh-on-idle/on-change.d/refresh-on-idle" "$SUBSCRIBERS/"
	"$PS" set working --pane "$pa"
	sleep 0.3
	rm -f "$WORK/gh.log"
	"$PS" set idle --pane "$pa"
	eventually_eq "refresh-on-idle: an agent going idle looks up" yes sh -c "[ -s '$WORK/gh.log' ] && echo yes"
	rm "$SUBSCRIBERS/refresh-on-idle"
	"$PS" clear --pane "$pa"

	t set-option -g @pane-status-gh-interval 0
	"$PS" refresh
	eventually_eq "interval 0 clears pull requests" "    " record "$pa"
	eventually_eq "interval 0 stops the poller" 0 sh -c "ps -A -o args= | grep -c '[p]ane-status poll'"
	"$PS" refresh 2>/dev/null
	assert_eq "refresh fails without a poller" 1 "$?"
	t -C attach-session -t test </dev/null >/dev/null 2>&1
	sleep 0.5
	assert_eq "attaching without a poller shows no error" 0 "$(t list-panes -a -F '#{pane_in_mode}' | grep -c 1)"
	t set-option -gu @pane-status-gh-interval
	rm -rf "$SUBSCRIBERS" "$BIN/gh"
	for p in "$pa" "$pe" "$pw" "$pb" "$pc" "$pd"; do t kill-window -t "$p"; done
}
if [ -n "$HAVE_JQ" ] && command -v git >/dev/null 2>&1; then
	gh_tests
else
	printf 'skip gh tests (jq or git not installed)\n'
fi

# --- recipes ------------------------------------------------------------------

# Recipes use only the public interface: pane options, list and notifications.

t source-file "$RECIPES/formats/formats.tmux"
render() { t display-message -p -t "$1" "$(t show-option -gqv "$2")"; }
P7="$(t split-window -d -P -F '#{pane_id}' -t "$P3")"
"$PS" set working --pane "$P3"
"$PS" set idle --pane "$P7"
"$PS" set waiting --pane "$P7"
"$PS" set idle --pane "$P7"
t set-option -p -t "$P3" @pane-status_pr_number 42 \; set-option -p -t "$P3" @pane-status_pr_state open \; \
	set-option -p -t "$P3" @pane-status_pr_draft 0 \; set-option -p -t "$P3" @pane-status_pr_review required \; \
	set-option -p -t "$P3" @pane-status_pr_checks failure
assert_eq "formats: window shows the most urgent state and the pull request" "1 zsh (working) #42 review ✗" \
	"$(render "$P3" window-status-format | sed 's/^1 [^ ]*/1 zsh/')"
assert_eq "formats: an unseen idle pane is done" " (done) " "$(render "$P7" pane-border-format)"
"$PS" set error --pane "$P7"
assert_eq "formats: error outranks working" "(error)" "$(render "$P3" window-status-format | grep -o '(error)')"

if [ -n "$HAVE_JQ" ]; then
	t select-window -t "$P1"
	eventually_eq "next: starting elsewhere" "$P1" current_pane
	printf 'run-shell "sh %s"\n' "$RECIPES/next/next.sh" >&3
	eventually_eq "next: jumps to the most urgent pane" "$P7" current_pane

	printf '#!/bin/sh\nhead -n 1\n' >"$BIN/fzf"
	chmod +x "$BIN/fzf"
	t select-window -t "$P1"
	eventually_eq "picker: starting elsewhere" "$P1" current_pane
	"$PS" set waiting --pane "$P3"
	sh "$RECIPES/picker/picker.sh"
	eventually_eq "picker: jumps to the chosen pane" "$P3" current_pane
	rm "$BIN/fzf"
fi

mkdir -p "$SUBSCRIBERS"
cp "$RECIPES/auto-seen/on-change.d/auto-seen" "$SUBSCRIBERS/"
t source-file "$RECIPES/auto-seen/auto-seen.tmux"
t select-pane -t "$P3"
eventually_eq "auto-seen: on screen" "$P3" current_pane
"$PS" set idle --pane "$P3"
eventually_eq "auto-seen: a change on screen is seen" 1 opt "$P3" agent_seen
"$PS" set working --pane "$P7"
assert_eq "auto-seen: a change off screen is not" 0 "$(opt "$P7" agent_seen)"
t select-pane -t "$P7"
eventually_eq "auto-seen: switching to a pane marks it seen" 1 opt "$P7" agent_seen
rm -rf "$SUBSCRIBERS"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
