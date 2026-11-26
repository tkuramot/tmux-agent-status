#!/usr/bin/env bash
# pane-status list: the JSON contract.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

"$PS" list --require-schema 2 >/dev/null 2>&1
assert_eq "list fails for another schema" 1 "$?"
if [ -z "$HAVE_JQ" ]; then
	printf 'skip list tests (jq not installed)\n'
	finish
	exit
fi

P2="$(split_pane "$P1")"
"$PS" agent set error --pane "$P1" --agent my-agent
t rename-window -t "$P1" 'say "hi"' \; select-pane -t "$P1" -T 'a title'
# shellcheck disable=SC2016
assert_eq "list reports panes as documented" \
	"1|$P1|test|0|say \"hi\"|a title|my-agent|error|true|null|$P2|null|null" \
	"$("$PS" list --require-schema 1 | jq -r --arg p1 "$P1" --arg p2 "$P2" '
		(.panes[] | select(.pane == $p1)) as $a | (.panes[] | select(.pane == $p2)) as $b
		| [.schema_version, $a.pane, $a.session, $a.window_index, $a.window_name,
			$a.title, $a.agent.name, $a.agent.activity, $a.agent.seen, ($a.pr | tojson),
			$b.pane, ($b.title | tojson), ($b.agent | tojson)] | join("|")')"

t link-window -s test:0 -t test:9
assert_eq "list shows a linked pane once" 1 "$("$PS" list | jq --arg p "$P1" '[.panes[] | select(.pane == $p)] | length')"
t unlink-window -t test:9

odd="$WORK/esc$(printf '\033')\\dir"
mkdir -p "$odd" "$WORK/new
line"
po="$(new_pane "$odd")"
new_pane "$WORK/new
line" >/dev/null
assert_eq "list escapes control characters" "$(cd -P "$odd" && pwd)" \
	"$("$PS" list | jq -r --arg p "$po" '.panes[] | select(.pane == $p) | .path')"
assert_eq "list keeps a path with a newline from splitting its record" \
	"$(t list-panes -a -F '#{pane_id}' | sort -u | xargs)" "$("$PS" list | jq -r '.panes[].pane' | sort | xargs)"

finish
