#!/usr/bin/env bash
# The TPM entry point: hooks, formats left alone, and the dead-pane hook.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

t set-option -g remain-on-exit on
P4="$(t new-window -d -P -F '#{pane_id}' -t test "tmux -S '$SOCKET' wait-for pane-status-test")"
emit "$P4" UserPromptSubmit
assert_eq "pane under remain-on-exit has state" working "$(activity "$P4")"
t wait-for -S pane-status-test
eventually_eq "pane is dead" 1 t display-message -p -t "$P4" '#{pane_dead}'
eventually_eq "a dead pane under remain-on-exit is cleared" "" activity "$P4"

assert_eq "version is unknown outside a git checkout" "pane-status unknown" "$("$PS" version)"
if command -v git >/dev/null 2>&1; then
	cp -R "$WORK/plugin" "$WORK/checkout"
	git -C "$WORK/checkout" init -q
	git -C "$WORK/checkout" add -A
	git -C "$WORK/checkout" -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null \
		commit -q -m init
	assert_eq "version is the checkout's commit" \
		"pane-status $(git -C "$WORK/checkout" rev-parse --short HEAD)" "$("$WORK/checkout/bin/pane-status" version)"
	touch "$WORK/checkout/lib/new"
	git -C "$WORK/checkout" add lib/new
	assert_eq "version marks uncommitted changes" "-dirty" \
		"$("$WORK/checkout/bin/pane-status" version | grep -o -- '-dirty')"
	mkdir "$WORK/outer"
	cp -R "$WORK/plugin" "$WORK/outer/plugin"
	git -C "$WORK/outer" init -q
	assert_eq "version ignores a repository the plugin is merely inside" \
		"pane-status unknown" "$("$WORK/outer/plugin/bin/pane-status" version)"
	assert_eq "version ignores GIT_DIR from the environment" "pane-status unknown" \
		"$(GIT_DIR="$WORK/checkout/.git" "$PS" version)"
fi

finish
