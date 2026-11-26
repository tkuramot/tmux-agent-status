#!/usr/bin/env bash
# Recipes, run as copied: they may use only the public interfaces (pane
# options, list, notifications and the CLI), so these are contract tests.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

attach_client
P3="$(new_pane "$WORK")"
P7="$(split_pane "$P3")"

# --- formats ------------------------------------------------------------------

t source-file "$RECIPES/formats/formats.tmux"
render() { t display-message -p -t "$1" "$(t show-option -gqv "$2")"; }
"$PS" agent set working --pane "$P3"
"$PS" agent set idle --pane "$P7"
"$PS" agent set waiting --pane "$P7"
"$PS" agent set idle --pane "$P7"
t set-option -p -t "$P3" @pane-status_pr_number 42 \; set-option -p -t "$P3" @pane-status_pr_state open \; \
	set-option -p -t "$P3" @pane-status_pr_draft 0 \; set-option -p -t "$P3" @pane-status_pr_review required \; \
	set-option -p -t "$P3" @pane-status_pr_checks failure
assert_eq "formats: window shows the most urgent state and the pull request" "1 zsh (working) #42 review ✗" \
	"$(render "$P3" window-status-format | sed 's/^1 [^ ]*/1 zsh/')"
assert_eq "formats: an unseen idle pane is done" " (done) " "$(render "$P7" pane-border-format)"
"$PS" agent set error --pane "$P7"
assert_eq "formats: error outranks working" "(error)" "$(render "$P3" window-status-format | grep -o '(error)')"

if [ -n "$HAVE_JQ" ]; then
	# --- next -------------------------------------------------------------------

	t select-window -t "$P1"
	eventually_eq "next: starting elsewhere" "$P1" current_pane
	printf 'run-shell "sh %s"\n' "$RECIPES/next/next.sh" >&3
	eventually_eq "next: jumps to the most urgent pane" "$P7" current_pane

	# --- agents -----------------------------------------------------------------

	# Fake fzf: logs the header line and picks the first row.
	# shellcheck disable=SC2016
	printf '#!/bin/sh\nIFS= read -r header; echo "$header" >"%s"; head -n 1\n' "$WORK/fzf.header" >"$BIN/fzf"
	chmod +x "$BIN/fzf"
	t select-window -t "$P1"
	eventually_eq "agents: starting elsewhere" "$P1" current_pane
	"$PS" agent set waiting --pane "$P3"
	sh "$RECIPES/agents/agents.sh"
	eventually_eq "agents: jumps to the most urgent pane" "$P3" current_pane
	assert_eq "agents: the header counts every state" "$(printf '\t')waiting 1 · error 1 · done 0 · working 0 · idle 0" \
		"$(cat "$WORK/fzf.header")"
	rm "$BIN/fzf"
fi

# --- auto-seen ----------------------------------------------------------------

mkdir -p "$SUBSCRIBERS"
cp "$RECIPES/auto-seen/on-change.d/auto-seen" "$SUBSCRIBERS/"
t source-file "$RECIPES/auto-seen/auto-seen.tmux"
t select-pane -t "$P3"
eventually_eq "auto-seen: on screen" "$P3" current_pane
"$PS" agent set idle --pane "$P3"
eventually_eq "auto-seen: a change on screen is seen" 1 opt "$P3" agent_seen
"$PS" agent set working --pane "$P7"
assert_eq "auto-seen: a change off screen is not" 0 "$(opt "$P7" agent_seen)"
t select-pane -t "$P7"
eventually_eq "auto-seen: switching to a pane marks it seen" 1 opt "$P7" agent_seen
rm -rf "$SUBSCRIBERS"

# --- refresh-on-idle ------------------------------------------------------------

if command -v git >/dev/null 2>&1; then
	git init -q "$WORK/repo"
	git -C "$WORK/repo" checkout -q -b feature
	git -C "$WORK/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
	pr="$(new_pane "$WORK/repo")"
	t set-option -g @pane-status-gh-interval 3600
	"$PLUGIN"
	eventually_eq "refresh-on-idle: the poller looked up once" 1 line_count "$WORK/gh.log"
	mkdir -p "$SUBSCRIBERS"
	cp "$RECIPES/refresh-on-idle/on-change.d/refresh-on-idle" "$SUBSCRIBERS/"
	"$PS" agent set working --pane "$pr"
	sleep 0.3
	assert_eq "refresh-on-idle: working does not look up" 1 "$(line_count "$WORK/gh.log")"
	"$PS" agent set idle --pane "$pr"
	eventually_eq "refresh-on-idle: going idle looks up" 2 line_count "$WORK/gh.log"
fi

finish
