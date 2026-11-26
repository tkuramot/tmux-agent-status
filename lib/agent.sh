# shellcheck shell=bash
# Agent state: adapters map an agent's hook events to activities, which are
# written to pane options.

ACTIVITIES="working waiting idle error"
ADAPTERS_DIR="$ROOT/adapters"

is_activity() {
	case " $ACTIVITIES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Agent names become path components.
is_valid_agent_name() {
	case "$1" in
	'' | *[!A-Za-z0-9_-]*) return 1 ;;
	*) return 0 ;;
	esac
}

# set_activity PANE ACTIVITY AGENT [FROM]: records a change of activity, and
# only a change, so repeated events (PreToolUse fires for every tool) neither
# reset since/seen nor notify. FROM, comma-separated activities, limits the
# change to panes in one of them. An agent's first activity counts as seen:
# nothing happened yet that you could have missed.
set_activity() {
	local pane="$1" activity="$2" agent="$3" from="${4:-}" st cmd
	local cond="#{!=:#{$OPT_AGENT_ACTIVITY},$activity}" any=""
	for st in ${from//,/ }; do
		if [ -z "$any" ]; then
			any="#{==:#{$OPT_AGENT_ACTIVITY},$st}"
		else
			any="#{||:#{==:#{$OPT_AGENT_ACTIVITY},$st},$any}"
		fi
	done
	[ -z "$any" ] || cond="#{&&:$cond,$any}"
	cmd="set-option -pF -t $pane $OPT_AGENT_SEEN '#{?#{$OPT_AGENT_ACTIVITY},0,1}'"
	cmd="$cmd ; set-option -p -t $pane $OPT_AGENT_ACTIVITY $activity"
	cmd="$cmd ; set-option -p -t $pane $OPT_AGENT_SINCE $(date +%s)"
	[ -z "$agent" ] || cmd="$cmd ; set-option -p -t $pane $OPT_AGENT_NAME $agent"
	if write_if "$pane" "$cond" "$cmd"; then notify agent "$pane"; fi
}

clear_agent() {
	local opt cmd=""
	for opt in "$OPT_AGENT_ACTIVITY" "$OPT_AGENT_SINCE" "$OPT_AGENT_SEEN" "$OPT_AGENT_NAME"; do
		cmd="$cmd${cmd:+ ; }set-option -pu -t $1 $opt"
	done
	if write_if "$1" "#{$OPT_AGENT_ACTIVITY}" "$cmd"; then notify agent "$1"; fi
}

mark_seen() {
	if write_if "$1" "#{&&:#{$OPT_AGENT_ACTIVITY},#{!=:#{$OPT_AGENT_SEEN},1}}" \
		"set-option -p -t $1 $OPT_AGENT_SEEN 1"; then
		notify agent "$1"
	fi
}

# --- adapters -------------------------------------------------------------

find_map() {
	local dir config
	config="$(config_dir)" || config=""
	for dir in ${config:+"$config/adapters"} "$ADAPTERS_DIR"; do
		[ -r "$dir/$1/map" ] && printf '%s' "$dir/$1/map" && return 0
	done
	return 1
}

# Prints "<action> <from-activities>" for an event.
lookup_event() {
	local key action from
	while read -r key action from _; do
		[ "$key" = "$2" ] || continue
		printf '%s %s' "$action" "$from"
		return 0
	done <"$1"
	return 1
}

validate_map() {
	local file="$1" lineno=0 errors=0 line key action from extra event seen=" " st
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		read -r key action from extra <<EOF
$line
EOF
		case "$key" in '' | '#'*) continue ;; esac
		set --
		[ -z "$extra" ] || set -- "$@" "too many fields"
		[ -n "$action" ] || set -- "$@" "missing action"
		case "$key" in
		*:*:* | :* | *: | *[!A-Za-z0-9_.:\|*-]*) set -- "$@" "invalid event: $key" ;;
		esac
		if [ "$action" = clear ]; then
			[ -z "$from" ] || set -- "$@" "clear takes no from-activities"
		elif [ -n "$action" ] && ! is_activity "$action"; then
			set -- "$@" "unknown action: $action"
		fi
		for st in ${from//,/ }; do
			is_activity "$st" || set -- "$@" "unknown from-activity: $st"
		done
		event="${key%%:*}"
		case "$seen" in *" $key "*) set -- "$@" "duplicate event: $key" ;; esac
		case "$key" in
		*:*) case "$seen" in *" $event "*) set -- "$@" "$key overlaps $event; both hooks would fire" ;; esac ;;
		*) case "$seen" in *" $event:"*) set -- "$@" "$key overlaps $event:*; both hooks would fire" ;; esac ;;
		esac
		seen="$seen$key "
		for st in "$@"; do
			printf '%s:%d: %s\n' "$file" "$lineno" "$st" >&2
			errors=$((errors + 1))
		done
	done <"$file"
	[ "$errors" -eq 0 ]
}

json_string() {
	local s="${1//\\/\\\\}"
	printf '"%s"' "${s//\"/\\\"}"
}

# Claude Code settings shape: one hook group per entry; `Event:detail` becomes
# a matcher on Event.
print_hooks() {
	local agent="$1" map="$2" key events="" event first_event=1 first_group
	case "$CLI" in *\'*) die "install path contains a single quote: $CLI" ;; esac
	while read -r key _; do
		case "$key" in '' | '#'*) continue ;; esac
		case " $events " in *" ${key%%:*} "*) ;; *) events="$events ${key%%:*}" ;; esac
	done <"$map"

	printf '{\n  "hooks": {'
	for event in $events; do
		[ "$first_event" = 1 ] || printf ','
		first_event=0
		printf '\n    %s: [' "$(json_string "$event")"
		first_group=1
		while read -r key _; do
			case "$key" in '' | '#'*) continue ;; esac
			[ "${key%%:*}" = "$event" ] || continue
			[ "$first_group" = 1 ] || printf ','
			first_group=0
			printf '\n      { '
			case "$key" in *:*) printf '"matcher": %s, ' "$(json_string "${key#*:}")" ;; esac
			printf '"hooks": [{ "type": "command", "timeout": 10, "command": %s }] }' \
				"$(json_string "'$CLI' agent emit $agent '$key'")"
		done <"$map"
		printf '\n    ]'
	done
	printf '\n  }\n}\n'
}

# Merges $new into the settings: drops the agent's hooks from an earlier
# install (any path), then appends $new's. A group or
# event is dropped only if it held nothing but ours. A blank file is {}.
# shellcheck disable=SC2016
MERGE_JQ='
def ours: (objects | .command | strings | test($ours)) // false;
def mine: (objects | .hooks | arrays | any(.[]; ours)) // false;
def strip: if mine then .hooks |= map(select(ours | not)) else . end;
def gone: mine and (strip | .hooks == []);
def keep_event: if type == "array" and length > 0 then any(.[]; gone | not) else true end;
def strip_event: if type == "array" then map(select(gone | not) | strip) else . end;

[inputs] | if length > 1 then error("more than one JSON value") else .[0] // {} end
| if type != "object" then error("not a JSON object") else . end
| .hooks = (.hooks // {}
	| with_entries(select(.value | keep_event) | .value |= strip_event)
	| reduce ($new.hooks | to_entries[]) as $e (.; .[$e.key] = (.[$e.key] // []) + $e.value))'

# install_hooks AGENT MAP FILE: merges the hooks into the settings FILE. A
# symlink is followed, so it stays a symlink, and its target is replaced only
# once the merge succeeded, by a copy that keeps its mode.
install_hooks() {
	local file="$3" hooks merged dir tmp
	command -v jq >/dev/null 2>&1 || die "--install needs jq"
	hooks="$(print_hooks "$1" "$2")" || exit 1
	while [ -L "$file" ]; do
		dir="$(cd -P "$(dirname "$file")" && pwd)" || die "cannot resolve $3"
		file="$(readlink "$file")"
		case "$file" in /*) ;; *) file="$dir/$file" ;; esac
	done
	if [ ! -e "$file" ]; then
		if ! { mkdir -p "$(dirname "$file")" && : >"$file"; }; then
			die "cannot create $file"
		fi
	fi
	merged="$(jq -n --argjson new "$hooks" --arg ours "/bin/pane-status' agent emit $1 " "$MERGE_JQ" "$file")" ||
		die "not changed: could not merge into $file"
	tmp="$file.pane-status.$$"
	if ! { cp -p "$file" "$tmp" && printf '%s\n' "$merged" >"$tmp" && mv -f "$tmp" "$file"; }; then
		rm -f "$tmp"
		die "cannot write $file"
	fi
	printf 'installed %s hooks in %s\n' "$1" "$3"
}

emit_event() {
	local agent="${1:-}" event="${2:-}" map action from
	[ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] && [ -n "$event" ] || return 0
	command -v tmux >/dev/null 2>&1 || return 0
	is_valid_agent_name "$agent" || return 0
	map="$(find_map "$agent")" || return 0
	read -r action from <<EOF
$(lookup_event "$map" "$event")
EOF
	case "$action" in
	clear) clear_agent "$TMUX_PANE" ;;
	*) ! is_activity "$action" || set_activity "$TMUX_PANE" "$action" "$agent" "$from" ;;
	esac
	return 0
}
