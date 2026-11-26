# shellcheck shell=bash
# Pull requests: a poller looks up the pull request of each pane's branch and
# writes it to pane options.

GH_INTERVAL_DEFAULT=60
# A record without a pull request: one empty value per option in OPT_PRS.
NO_PR=$'\t\t\t\t\t'

# One request per repository covers all of its checked-out branches: branch
# i is queried as alias b<i>.
PR_FRAGMENT='fragment pr on PullRequest { number url state isDraft reviewDecision
	isCrossRepository headRepositoryOwner { login }
	commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } }'

# Prints "<i>\t<number>\t<url>\t<state>\t<draft>\t<review>\t<checks>" for each
# branch with a pull request, renaming GitHub's values to the plugin's.
# Branch names are not unique across forks, so a pull request from a fork
# counts only if the fork is yours. statusCheckRollup.state is GitHub's own
# summary of the checks.
# shellcheck disable=SC2016
PR_JQ='.data.viewer.login as $me | .data.repository | to_entries[]
| (.value.nodes | map(select((.isCrossRepository | not) or .headRepositoryOwner.login == $me)) | .[0] // empty) as $p
| [(.key | ltrimstr("b")), $p.number, $p.url, ($p.state | ascii_downcase),
	(if $p.isDraft then 1 else 0 end),
	({"APPROVED": "approved", "CHANGES_REQUESTED": "changes_requested", "REVIEW_REQUIRED": "required"}[$p.reviewDecision // ""] // "none"),
	({"SUCCESS": "success", "FAILURE": "failure", "ERROR": "failure", "PENDING": "pending", "EXPECTED": "pending"}[$p.commits.nodes[0].commit.statusCheckRollup.state // ""] // "none")]
| @tsv'

gh_interval() {
	local value
	value="$(get_tmux_option @pane-status-gh-interval "$GH_INTERVAL_DEFAULT")"
	case "$value" in *[!0-9]*) value="$GH_INTERVAL_DEFAULT" ;; esac
	printf '%s' "$value"
}

# Prints "<repository>$US<branch>" for the branch checked out in DIR. The
# repository is git's common directory, shared by all its worktrees.
repo_branch() {
	local out ref
	[ -n "$1" ] || return 1
	out="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir --symbolic-full-name HEAD 2>/dev/null)" || return 1
	ref="${out#*$'\n'}"
	case "$ref" in refs/heads/*) printf '%s%s%s' "${out%%$'\n'*}" "$US" "${ref#refs/heads/}" ;; *) return 1 ;; esac
}

# Prints the host of the remote gh uses in DIR: the one `gh repo set-default`
# chose, else upstream, github, origin, else the first.
remote_host() {
	local remote url host
	remote="$(git -C "$1" config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null)"
	remote="${remote#remote.}"
	remote="${remote%%.gh-resolved *}"
	if [ -z "$remote" ]; then
		for remote in upstream github origin $(git -C "$1" remote) ''; do
			git -C "$1" remote get-url "$remote" >/dev/null 2>&1 && break
		done
	fi
	url="$(git -C "$1" remote get-url "$remote" 2>/dev/null)" || return 1
	case "$url" in
	*://*) host="${url#*://}" host="${host#*@}" ;;
	*@*:*) host="${url#*@}" ;;
	*) return 1 ;;
	esac
	printf '%s' "${host%%[:/]*}"
}

# query_prs DIR BRANCH...: one GraphQL request, run in DIR so that gh picks
# the repository (and `gh repo set-default`) from there. `gh api` sends to its
# default host whatever the repository, so the remote's host is passed when gh
# is logged in to it (an SSH host alias is not).
query_prs() {
	local dir="$1" i=0 vars="" fields="" branch host
	local -a args=()
	shift
	if host="$(remote_host "$dir")" && gh auth token --hostname "$host" >/dev/null 2>&1; then
		args+=(--hostname "$host")
	fi
	for branch in "$@"; do
		vars="$vars, \$b$i: String!"
		fields="$fields b$i: pullRequests(headRefName: \$b$i, first: 20, states: [OPEN, MERGED, CLOSED], orderBy: {field: CREATED_AT, direction: DESC}) { nodes { ...pr } }"
		args+=(-f "b$i=$branch")
		i=$((i + 1))
	done
	(cd "$dir" && gh api graphql -F owner='{owner}' -F repo='{repo}' "${args[@]}" \
		-f query="query(\$owner: String!, \$repo: String!$vars) { viewer { login } repository(owner: \$owner, name: \$repo) {$fields } } $PR_FRAGMENT" \
		--jq "$PR_JQ")
}

# write_pr PANE RECORD: RECORD holds the values of OPT_PRS, tab-separated;
# empty values unset their option.
write_pr() {
	local -a args=()
	local opt value rest="$2"$'\t'
	for opt in $OPT_PRS; do
		value="${rest%%$'\t'*}"
		rest="${rest#*$'\t'}"
		if [ -n "$value" ]; then
			args+=(set-option -p -t "$1" "$opt" "$value" \;)
		else
			args+=(set-option -pu -t "$1" "$opt" \;)
		fi
	done
	tmux "${args[@]}" 2>/dev/null
}

# The poll's working set, one entry per pane; filled by read_panes.
PANES=() DIRS=() REPOS=() BRANCHES=() OLD=() NEW=()

# read_panes [--clear]: resolves each live pane's repository and branch;
# with --clear, none.
read_panes() {
	local format="" opt pane dead old path line seen=" " n=0
	for opt in $OPT_PRS; do format="$format${format:+$'\t'}#{$opt}"; done
	PANES=() DIRS=() REPOS=() BRANCHES=() OLD=() NEW=()
	while IFS="$US" read -r pane dead old path; do
		# Linked windows list a pane more than once; a path with a newline
		# continues on a line of its own, which is skipped.
		case "$seen" in *" $pane "*) continue ;; esac
		case "$pane" in %*) ;; *) continue ;; esac
		seen="$seen$pane "
		line=""
		[ -n "${1:-}" ] || [ "$dead" = 1 ] || line="$(repo_branch "$path")" || line=""
		PANES[n]="$pane" DIRS[n]="$path" OLD[n]="$old" NEW[n]="$NO_PR"
		REPOS[n]="${line%%"$US"*}" BRANCHES[n]="${line#*"$US"}"
		n=$((n + 1))
	done < <(tmux list-panes -a -F "#{pane_id}$US#{pane_dead}$US$format$US#{pane_current_path}")
}

# lookup_repo I: looks up the branches of pane I's repository in one request
# and fills NEW for all panes of that repository.
lookup_repo() {
	local repo="${REPOS[$1]}" i k rest
	local -a branches=()
	for ((i = $1; i < ${#PANES[@]}; i++)); do
		[ "${REPOS[i]}" = "$repo" ] || continue
		for ((k = 0; k < ${#branches[@]}; k++)); do
			[ "${branches[k]}" != "${BRANCHES[i]}" ] || break
		done
		branches[k]="${BRANCHES[i]}"
	done
	while IFS=$'\t' read -r k rest; do
		for ((i = $1; i < ${#PANES[@]}; i++)); do
			if [ "${REPOS[i]}" = "$repo" ] && [ "${BRANCHES[i]}" = "${branches[k]}" ]; then
				NEW[i]="$rest"
			fi
		done
	done < <(query_prs "${DIRS[$1]}" "${branches[@]}" 2>/dev/null)
}

# poll_once [--clear]: updates every pane's pull request and notifies once for
# the panes that changed. A failed lookup clears its panes.
poll_once() {
	local i looked_up="$US" changed=""
	read_panes "$@"
	for ((i = 0; i < ${#PANES[@]}; i++)); do
		[ -n "${REPOS[i]}" ] || continue
		case "$looked_up" in *"$US${REPOS[i]}$US"*) continue ;; esac
		looked_up="$looked_up${REPOS[i]}$US"
		lookup_repo "$i"
	done
	for ((i = 0; i < ${#PANES[@]}; i++)); do
		[ "${NEW[i]}" != "${OLD[i]}" ] || continue
		write_pr "${PANES[i]}" "${NEW[i]}" && changed="$changed ${PANES[i]}"
	done
	# shellcheck disable=SC2086
	[ -z "$changed" ] || notify gh $changed
}

# Polls every @pane-status-gh-interval seconds while a client is attached.
# `refresh` (SIGUSR1) cuts the wait short. The plugin runs it as a tmux job,
# so it dies with the server; it also exits when another poller takes over.
cmd_poll() {
	local interval again="" old claim
	trap 'again=1' USR1
	# Claimed in one tmux command, so of two pollers started together one exits.
	# (The condition is a variable: bash 3.2 brace-expands it inside "$(...)".)
	old="$(tmux show-option -gqv "$OPT_POLLER_PID" 2>/dev/null)" || return 0
	claim="#{==:#{$OPT_POLLER_PID},$old}"
	[ "$(tmux if-shell -F "$claim" "set-option -g $OPT_POLLER_PID $$ ; display-message -p 1" 2>/dev/null)" = 1 ] ||
		return 0
	while [ "$(tmux show-option -gqv "$OPT_POLLER_PID" 2>/dev/null)" = "$$" ]; do
		interval="$(gh_interval)"
		if [ "$interval" = 0 ]; then
			poll_once --clear
			tmux set-option -gu "$OPT_POLLER_PID"
			return 0
		fi
		again=""
		[ -z "$(tmux list-clients 2>/dev/null)" ] || poll_once
		# A refresh during the poll may be about a pane it already read.
		[ -z "$again" ] || continue
		sleep "$interval" &
		[ -n "$again" ] || wait "$!"
		kill "$!" 2>/dev/null
	done
}

cmd_refresh() {
	local pid
	pid="$(poller_pid)" || die "the poller is not running"
	kill -USR1 "$pid"
}
