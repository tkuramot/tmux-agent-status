#!/usr/bin/env bash
# Agent state: emit, activities, seen, notifications, set, adapters.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

P2="$(split_pane "$P1")"

# --- emit contract ----------------------------------------------------------

out="$(printf '{"x":1}' | env -u TMUX -u TMUX_PANE "$PS" agent emit claude-code Stop 2>&1)"
assert_eq "emit outside tmux is a silent no-op" "0:" "$?:$out"
out="$(printf '{"x":1}' | TMUX_PANE="$P1" "$PS" agent emit no-such-agent Stop 2>&1)"
assert_eq "emit with unknown agent is a silent no-op" "0:" "$?:$out"
out="$(TMUX_PANE="$P1" "$PS" agent emit ../../etc Stop </dev/null 2>&1)"
assert_eq "emit rejects path-like agent names" "0:" "$?:$out"
out="$(TMUX_PANE="$P1" "$PS" agent emit claude-code NoSuchEvent </dev/null 2>&1)"
assert_eq "emit with unknown event is a no-op" "0::" "$?:$out:$(activity "$P1")"
out="$(TMUX_PANE=%999 "$PS" agent emit claude-code Stop </dev/null 2>&1)"
assert_eq "emit for a missing pane is a silent no-op" "0:" "$?:$out"
mkfifo "$WORK/stdin"
exec 4<>"$WORK/stdin"
start=$(date +%s)
TMUX_PANE="$P1" "$PS" agent emit claude-code NoSuchEvent <"$WORK/stdin"
assert_eq "emit does not wait for stdin to close" 1 "$(($(date +%s) - start < 4))"
exec 4>&-
# Time emit alone: a pipeline would also wait for the writer.
mkfifo "$WORK/trickle"
(for _ in 1 2 3 4 5 6 7 8 9 10; do printf '{}\n'; sleep 0.5; done) >"$WORK/trickle" 2>/dev/null &
writer=$!
start=$(date +%s)
TMUX_PANE="$P1" "$PS" agent emit claude-code NoSuchEvent <"$WORK/trickle"
assert_eq "emit stops draining a trickling stdin at its deadline" 1 "$(($(date +%s) - start < 4))"
kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
out="$(env -u HOME -u XDG_CONFIG_HOME TMUX_PANE="$P1" "$PS" agent emit claude-code NoSuchEvent </dev/null 2>&1)"
assert_eq "emit without HOME is a silent no-op" "0:" "$?:$out"

# --- activity, since and seen ------------------------------------------------

out="$(printf '{"session_id":"abc"}' | TMUX_PANE="$P1" "$PS" agent emit claude-code SessionStart:startup 2>&1)"
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
"$PS" agent seen --pane "$P1"
assert_eq "seen marks the activity seen" "idle:1" "$(activity "$P1"):$(opt "$P1" agent_seen)"
emit "$P2" Notification:permission_prompt
assert_eq "matcher events map through the adapter" waiting "$(activity "$P2")"

cond_map="$XDG_CONFIG_HOME/tmux-pane-status/adapters/cond/map"
mkdir -p "$(dirname "$cond_map")"
printf 'Calm idle working,waiting\n' >"$cond_map"
TMUX_PANE="$P2" "$PS" agent emit cond Calm </dev/null
assert_eq "a conditional action applies from a listed activity" idle "$(activity "$P2")"
"$PS" agent set error --pane "$P2"
TMUX_PANE="$P2" "$PS" agent emit cond Calm </dev/null
assert_eq "a conditional action skips other activities" error "$(activity "$P2")"
rm -rf "$XDG_CONFIG_HOME/tmux-pane-status"

emit "$P1" 'SessionEnd:logout|prompt_input_exit|other'
assert_eq "SessionEnd clears every agent option" ":::" \
	"$(activity "$P1"):$(opt "$P1" agent_since):$(opt "$P1" agent_seen):$(opt "$P1" agent_name)"
"$PS" agent clear --pane "$P2"

# --- notifications ------------------------------------------------------------

subscribe_log
emit "$P1" UserPromptSubmit
eventually_eq "a change notifies its pane" "agent $P1" notified
: >"$WORK/notified"
emit "$P1" PreToolUse
emit "$P1" Stop
"$PS" agent seen --pane "$P1"
"$PS" agent seen --pane "$P1"
"$PS" agent clear --pane "$P1"
"$PS" agent clear --pane "$P1"
eventually_eq "changes, seen and clear notify; repeats do not" 3 line_count "$WORK/notified"
printf '#!/bin/sh\nsleep 5\n' >"$SUBSCRIBERS/slow"
chmod +x "$SUBSCRIBERS/slow"
start=$(date +%s)
emit "$P1" UserPromptSubmit
assert_eq "emit does not wait for subscribers" 1 "$(($(date +%s) - start < 2))"
rm -rf "$SUBSCRIBERS"
"$PS" agent clear --pane "$P1"

# --- set --------------------------------------------------------------------

"$PS" agent set bogus --pane "$P1" 2>/dev/null
assert_eq "set rejects unknown activities" 1 "$?"
"$PS" agent set "done" --pane "$P1" 2>/dev/null
assert_eq "done is not an activity" 1 "$?"
"$PS" agent set working --pane %999 2>/dev/null
assert_eq "set rejects missing panes" 1 "$?"
TMUX_PANE="$P1" "$PS" agent set working --pane "" 2>/dev/null
assert_eq "an explicit empty --pane is an error" "1:" "$?:$(activity "$P1")"
"$PS" agent set error --pane "$P1" --agent my-agent
assert_eq "set works without an adapter" "error:my-agent" "$(activity "$P1"):$(opt "$P1" agent_name)"
"$PS" agent clear --pane "$P1"

assert_eq "a group without a command is an error" 1 "$("$PS" agent 2>/dev/null; echo $?)"

# --- adapters ---------------------------------------------------------------

user_map="$XDG_CONFIG_HOME/tmux-pane-status/adapters/claude-code/map"
mkdir -p "$(dirname "$user_map")"
printf 'Stop error\n' >"$user_map"
emit "$P1" Stop
assert_eq "user adapter overrides the built-in one" error "$(activity "$P1")"
printf 'Stop done\nStop idle x y\nA:b idle\nA idle\nBad/Event idle\nC clear working\n  # indented comment\n' >"$user_map"
errors="$("$PS" agent check claude-code 2>&1 >/dev/null)"
assert_eq "check exits non-zero for a bad map" 1 "$("$PS" agent check claude-code >/dev/null 2>&1; echo $?)"
assert_eq "check reports every problem" 7 "$(printf '%s\n' "$errors" | wc -l | tr -d ' ')"
rm -rf "$XDG_CONFIG_HOME/tmux-pane-status"
"$PS" agent clear --pane "$P1"

assert_eq "built-in map is valid" 0 "$("$PS" agent check claude-code >/dev/null; echo $?)"
assert_eq "the CLI works through a symlink" 0 "$("$BIN/pane-status" agent check claude-code >/dev/null; echo $?)"
if [ -n "$HAVE_JQ" ]; then
	expected="$(grep -v -e '^#' -e '^$' "$ROOT/adapters/claude-code/map" | awk '{ print $1 }')"
	# shellcheck disable=SC2016
	actual="$("$PS" agent hooks claude-code | jq -r '.hooks | to_entries[] | .key as $e | .value[] |
		(if .matcher then "\($e):\(.matcher)" else $e end) as $k |
		select(.hooks[0].command | endswith(" emit claude-code '\''\($k)'\''")) | $k')"
	assert_eq "hooks cover every map entry with a matching command" "$expected" "$actual"

	assert_eq "hooks call the grouped command" 0 \
		"$("$PS" agent hooks claude-code | jq '[.hooks[][].hooks[].command | select(contains("'\'' agent emit claude-code '\''") | not)] | length')"

	export CLAUDE_CONFIG_DIR="$WORK/claude"
	settings="$CLAUDE_CONFIG_DIR/settings.json"
	install() { "$PS" agent hooks claude-code --install >/dev/null; }
	generated() { "$PS" agent hooks claude-code | jq -S .; }
	installed() { jq -S . "$settings"; }

	install
	assert_eq "install creates the settings" "$(generated)" "$(installed)"
	: >"$settings"
	install
	assert_eq "install takes a blank file as {}" "$(generated)" "$(installed)"

	hook() { printf '{"type":"command","command":"%s"}' "$1"; }
	mine="$(hook my-hook)"
	other="$(hook "'/old/place/bin/pane-status' agent emit my-agent Stop")"
	old="$(hook "'/old/place/bin/pane-status' agent emit claude-code Stop")"
	printf '{"model":"x","hooks":{"Stop":[{"hooks":[%s,%s,%s]},{"matcher":"m"}],"Other":[],"PreCompact":[{"hooks":[%s]}]}}' \
		"$mine" "$old" "$other" "$old" >"$settings"
	install
	assert_eq "install replaces ours from any path and leaves the rest in place" \
		"$(generated | jq -S --argjson a "$mine" --argjson b "$other" \
			'.model = "x" | .hooks.Other = [] | .hooks.Stop = [{"hooks": [$a, $b]}, {"matcher": "m"}] + .hooks.Stop')" \
		"$(installed)"
	cp "$settings" "$WORK/once.json"
	install
	assert_eq "install twice changes nothing" "" "$(cmp "$WORK/once.json" "$settings")"

	printf '{}' >"$WORK/real.json"
	chmod 600 "$WORK/real.json"
	ln -sf ../real.json "$settings"
	install
	assert_eq "install writes through a symlink" "../real.json $(generated)" "$(readlink "$settings") $(installed)"
	assert_eq "install keeps the mode" "$WORK/real.json" "$(find "$WORK/real.json" -perm 600)"
	for bad in '{' '{} {}' '[]'; do
		printf '%s' "$bad" >"$settings"
		"$PS" agent hooks claude-code --install 2>/dev/null
		assert_eq "install leaves $bad alone" "1 $bad" "$? $(cat "$settings")"
	done
	assert_eq "install leaves no temporary file" "real.json" "$(cd "$WORK" && ls real.json*)"

	mkdir -p "$XDG_CONFIG_HOME/tmux-pane-status/adapters/my-agent"
	printf 'done idle\n' >"$XDG_CONFIG_HOME/tmux-pane-status/adapters/my-agent/map"
	assert_eq "install is for claude-code only" "pane-status: --install supports claude-code only; merge the printed settings yourself" \
		"$("$PS" agent hooks my-agent --install 2>&1)"
	rm -rf "$XDG_CONFIG_HOME/tmux-pane-status"
	unset CLAUDE_CONFIG_DIR
fi

# --- concurrency ------------------------------------------------------------

P5="$(split_pane "$P1")"
P6="$(split_pane "$P1")"
for _ in 1 2 3 4 5 6 7 8; do
	for p in "$P1" "$P5" "$P6"; do
		emit "$p" UserPromptSubmit &
		emit "$p" Notification:permission_prompt &
	done
done
wait
"$PS" agent set working --pane "$P1" & "$PS" agent set waiting --pane "$P5" & "$PS" agent set error --pane "$P6" &
wait
assert_eq "activities are consistent after concurrent updates" "working waiting error" \
	"$(activity "$P1") $(activity "$P5") $(activity "$P6")"

finish
