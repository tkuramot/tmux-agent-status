#!/usr/bin/env bash
# Pull requests: the poller, its lookups through the fake gh, and refresh.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -z "$HAVE_JQ" ] || ! command -v git >/dev/null 2>&1; then
	printf 'skip gh tests (jq or git not installed)\n'
	finish
	exit
fi

# --- fixtures -------------------------------------------------------------

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
response() { # alias=pull-requests...: a GraphQL response; the viewer is "me"
	local a sep=""
	printf '{"data":{"viewer":{"login":"me"},"repository":{'
	for a; do printf '%s"%s":{"nodes":[%s]}' "$sep" "${a%%=*}" "${a#*=}"; sep=","; done
	printf '}}}'
}
mkdir -p "$WORK/prs"
response "b0=$(pr 99 CLOSED false null null stranger),$(pr 7 OPEN false '"CHANGES_REQUESTED"' '{"state":"ERROR"}')" \
	"b1=$(pr 70 OPEN true null null me)" >"$WORK/prs/ra.json"
cp "$WORK/prs/ra.json" "$WORK/prs/ra-other.json"
response "b0=$(pr 8 MERGED false '"APPROVED"' '{"state":"SUCCESS"}')" >"$WORK/prs/rb.json"

record() { t display-message -p -t "$1" '#{@pane-status_pr_number} #{@pane-status_pr_state} #{@pane-status_pr_draft} #{@pane-status_pr_review} #{@pane-status_pr_checks}'; }
calls() { if [ -r "$WORK/gh.log" ]; then cat "$WORK/gh.log"; fi; }

pa="$(new_pane "$WORK/ra")"
pe="$(new_pane "$WORK/ra")"
pw="$(new_pane "$WORK/ra-other")"
pb="$(new_pane "$WORK/rb")"
pc="$(new_pane "$WORK/rc")"
pd="$(new_pane "$WORK")"

# --- lookups ----------------------------------------------------------------

attach_client
t set-option -g @pane-status-gh-interval 3600
subscribe_log
"$PLUGIN" & load=$!
"$PLUGIN"
wait "$load"
eventually_eq "concurrent loads start a poller" 1 pollers
# The poll notifies after writing every pane, one at a time.
eventually_eq "one notification for all changed panes" 1 line_count "$WORK/notified"
# By now the losing poller has long given up its claim.
assert_eq "concurrent loads leave one poller" 1 "$(pollers)"
assert_eq "values are renamed, not combined; other forks are ignored" "7 open 0 changes_requested failure" "$(record "$pa")"
assert_eq "panes on the same branch share the result" "7 open 0 changes_requested failure" "$(record "$pe")"
assert_eq "a worktree is the same repository; your fork counts" "70 open 1 none none" "$(record "$pw")"
assert_eq "one lookup per repository, for all its branches" "ra 2
rb 1" "$(calls | sort)"
assert_eq "lookups go to the remote's host if gh is logged in to it" ra "$(sort -u "$WORK/gh.hosts")"
assert_eq "merged pull requests keep their checks" "8 merged 0 approved success" "$(record "$pb")"
assert_eq "the url is recorded" "https://github.com/o/r/pull/8" "$(opt "$pb" pr_url)"
assert_eq "detached HEAD has no pull request" "    " "$(record "$pc")"
assert_eq "a directory outside a repository has none" "    " "$(record "$pd")"
assert_eq "it names its source and the changed panes" "gh $(printf '%s\n' "$pa" "$pe" "$pw" "$pb" | sort | xargs)" \
	"$(cut -d ' ' -f 1 "$WORK/notified") $(cut -d ' ' -f 2- "$WORK/notified" | tr ' ' '\n' | sort | xargs)"
assert_eq "list reports the pull request" '{"number":8,"url":"https://github.com/o/r/pull/8","state":"merged","draft":false,"review":"approved","checks":"success"}' \
	"$("$PS" list | jq -c --arg p "$pb" '.panes[] | select(.pane == $p) | .pr')"

# --- refresh and changes ------------------------------------------------------

: >"$WORK/notified"
rm -f "$WORK/gh.log"
"$PS" refresh
eventually_eq "a refresh looks up again" 2 line_count "$WORK/gh.log"
sleep 0.3
assert_eq "unchanged pull requests notify nothing" "" "$(notified)"

git -C "$WORK/rc" checkout -q feature
rm "$WORK/prs/rb.json"
"$PS" refresh
eventually_eq "a failed lookup clears its panes" "    " record "$pb"
assert_eq "a branch without a pull request has none" "    " "$(record "$pc")"

t set-option -g remain-on-exit on
dead="$(t new-window -d -P -F '#{pane_id}' -t test -c "$WORK/ra" true)"
eventually_eq "pane is dead" 1 t display-message -p -t "$dead" '#{pane_dead}'
"$PS" refresh
sleep 0.5
assert_eq "a dead pane is not looked up" "    " "$(record "$dead")"
t kill-pane -t "$dead" \; set-option -gu remain-on-exit

# --- stopping ---------------------------------------------------------------

t set-option -g @pane-status-gh-interval 0
"$PS" refresh
eventually_eq "interval 0 clears pull requests" "    " record "$pa"
eventually_eq "interval 0 stops the poller" 0 pollers
"$PS" refresh 2>/dev/null
assert_eq "refresh fails without a poller" 1 "$?"
t -C attach-session -t test </dev/null >/dev/null 2>&1
sleep 0.5
assert_eq "attaching without a poller shows no error" 0 "$(t list-panes -a -F '#{pane_in_mode}' | grep -c 1)"

finish
