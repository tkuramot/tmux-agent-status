# shellcheck shell=bash
# list: every pane's state as JSON. The schema is part of the public interface
# (see README): adding fields keeps SCHEMA_VERSION, other changes bump it.

SCHEMA_VERSION=1

# The helpers set variables rather than print, so a record costs no forks.

# to_string NAME: rewrites variable NAME as a JSON string, or null if empty.
to_string() {
	local value="${!1}" code octal char escape
	if [ -z "$value" ]; then
		printf -v "$1" null
		return
	fi
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	case "$value" in
	*[[:cntrl:]]*)
		for ((code = 1; code < 32; code++)); do
			printf -v octal '%03o' "$code"
			# shellcheck disable=SC2059 # the format is the octal escape
			printf -v char "\\$octal"
			printf -v escape '\\u%04x' "$code"
			value="${value//"$char"/$escape}"
		done
		;;
	esac
	printf -v "$1" '"%s"' "$value"
}

# to_number NAME: null unless a non-negative integer.
to_number() {
	case "${!1}" in '' | *[!0-9]*) printf -v "$1" null ;; esac
}

# to_bool NAME: "1" is true, anything else false.
to_bool() {
	if [ "${!1}" = 1 ]; then printf -v "$1" true; else printf -v "$1" false; fi
}

print_list() {
	local sep="" listed=" " agent pr opt format="#{pane_id}"
	local pane session window_index window_name pane_index path
	local name activity since seen_flag number url state draft review checks
	# The path is last: one with a newline continues on a line of its own,
	# which is skipped.
	for opt in session_name window_index window_name pane_index \
		"$OPT_AGENT_NAME" "$OPT_AGENT_ACTIVITY" "$OPT_AGENT_SINCE" "$OPT_AGENT_SEEN" $OPT_PRS pane_current_path; do
		format="$format$US#{$opt}"
	done

	printf '{"schema_version":%d,"panes":[' "$SCHEMA_VERSION"
	while IFS="$US" read -r pane session window_index window_name pane_index \
		name activity since seen_flag number url state draft review checks path; do
		case "$listed" in *" $pane "*) continue ;; esac
		case "$pane" in %*) ;; *) continue ;; esac
		listed="$listed$pane "

		agent=null
		if [ -n "$activity" ]; then
			to_string name
			to_string activity
			to_number since
			to_bool seen_flag
			agent="{\"name\":$name,\"activity\":$activity,\"since\":$since,\"seen\":$seen_flag}"
		fi
		pr=null
		if [ -n "$number" ]; then
			to_number number
			to_string url
			to_string state
			to_bool draft
			to_string review
			to_string checks
			pr="{\"number\":$number,\"url\":$url,\"state\":$state,\"draft\":$draft,\"review\":$review,\"checks\":$checks}"
		fi
		to_string pane
		to_string session
		to_number window_index
		to_string window_name
		to_number pane_index
		to_string path
		printf '%s\n{"pane":%s,"session":%s,"window_index":%s,"window_name":%s,"pane_index":%s,"path":%s,"agent":%s,"pr":%s}' \
			"$sep" "$pane" "$session" "$window_index" "$window_name" "$pane_index" "$path" "$agent" "$pr"
		sep=","
	done < <(tmux list-panes -a -F "$format")
	printf '\n]}\n'
}

cmd_list() {
	case "$#:${1:-}" in
	0:) ;;
	2:--require-schema)
		[ "$2" = "$SCHEMA_VERSION" ] ||
			die "schema $2 required, this version provides schema $SCHEMA_VERSION"
		;;
	*) die "usage: pane-status list [--require-schema N]" ;;
	esac
	print_list
}
