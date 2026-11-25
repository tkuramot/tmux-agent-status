#!/usr/bin/env bash
# TPM entry point. TPM discards output, so report problems with display-message.

shopt -u patsub_replacement 2>/dev/null

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
. "$CURRENT_DIR/scripts/helpers.sh"

# Fixed index: reloading replaces our hooks and leaves the user's alone.
HOOK_INDEX=7311

# Filled by modules/<name>/load.sh.
interpolations=()
TREE_PANE=""
TREE_WINDOW=""
TREE_SESSION=""

# tmux_version_at_least MAJOR MINOR
tmux_version_at_least() {
	local version major minor
	version="$(tmux -V 2>/dev/null)" || return 1
	version="${version#tmux }"
	version="${version#next-}"
	case "$version" in
	master | openbsd*) return 0 ;;
	[0-9]*.[0-9]*) ;;
	*) return 1 ;;
	esac
	major="${version%%.*}"
	minor="${version#*.}"
	minor="${minor%%[!0-9]*}"
	[ "$major" -gt "$1" ] || { [ "$major" -eq "$1" ] && [ "${minor:-0}" -ge "$2" ]; }
}

set_hook() {
	tmux set-hook -g "$1[$HOOK_INDEX]" "$2"
}

clear_hooks() {
	local hook
	for hook in $(tmux show-hooks -g | awk -v i="[$HOOK_INDEX]" 'index($1, i) { print $1 }'); do
		tmux set-hook -gu "$hook"
	done
}

interpolated_options=(
	status-left
	status-right
	window-status-format
	window-status-current-format
	pane-border-format
)

interpolate() {
	local value="$1" i
	for ((i = 0; i < ${#interpolations[@]}; i += 2)); do
		value="${value//"${interpolations[i]}"/${interpolations[i + 1]}}"
	done
	printf '%s' "$value"
}

update_formats() {
	local option value new
	for option in "${interpolated_options[@]}"; do
		value="$(tmux show-option -gqv "$option")"
		new="$(interpolate "$value")"
		[ "$new" = "$value" ] || tmux set-option -g "$option" "$new"
	done
}

# tmux 3.8's default choose-tree format plus each module's fragments.
tree_format() {
	local title='#{?#{&&:#{pane_title},#{!=:#{pane_title},#{host_short}}},: "#{pane_title}",}'
	local window_title='#{?#{&&:#{==:#{window_panes},1},#{&&:#{pane_title},#{!=:#{pane_title},#{host_short}}}},: "#{pane_title}",}'
	printf '%s' "#{?pane_format,\
#{?pane_marked,#[fg=thememagenta],}#{?pane_floating_flag,#[underscore],}#{pane_current_command}\
#[fg=themelightgrey]#{pane_flags}$TREE_PANE$title,\
window_format,\
#{?window_marked_flag,#[fg=thememagenta],}#{window_name}\
#[fg=themelightgrey]#{window_flags}$TREE_WINDOW$window_title,\
#[fg=themelightgrey]#{session_windows} windows#{?session_grouped, (group #{session_group}: #{session_group_list}),}\
#{?session_attached, (attached),}$TREE_SESSION}"
}

# chain LIST STATES RENDER: `RENDER <state>` for the first of STATES that
# the space-separated list LIST expands to contains.
chain() {
	local st out="" close=""
	for st in $2; do
		out="$out#{?#{m:*$st*,$1},$("$3" "$st"),"
		close="$close}"
	done
	printf '%s%s' "$out" "$close"
}

# Display of value $2 of module $1: @pane-status-$1-icon-$2, else <module>_default.
icon() {
	option_format "@pane-status-$1-icon-$2" "$("$1_default" "$2")"
}

# Tree fragments keep the normal colour on the tree's grey text.
tree_item() {
	printf ' #[fg=default]%s#[fg=themelightgrey]' "$1"
}

# Only tmux's default s/w bindings (or ours) are replaced.
bind_tree_keys() {
	local enabled kw key note words
	enabled="$(get_tmux_option @pane-status-choose-tree on)"
	tmux set-option -g "$OPT_TREE_FORMAT" "$(tree_format)"
	for kw in s:session w:window; do
		key="${kw%%:*}"
		note="Choose a ${kw#*:} from a list"
		read -r -a words <<<"$(tmux list-keys -T prefix "$key" 2>/dev/null)"
		if [ "$enabled" != off ]; then
			if [ "${words[*]:4}" = "choose-tree -Z$key" ]; then
				tmux bind-key -N "$note" "$key" choose-tree "-Z$key" -F "#{E:$OPT_TREE_FORMAT}"
			fi
		elif [ "${words[*]:4}" = "choose-tree -Z$key -F \"#{E:$OPT_TREE_FORMAT}\"" ]; then
			tmux bind-key -N "$note" "$key" choose-tree "-Z$key"
		fi
	done
}

main() {
	local module
	if ! tmux_version_at_least 3 8; then
		tmux display-message "tmux-pane-status requires tmux 3.8 or later"
		return 0
	fi
	# The path is embedded in tmux command strings and sh single quotes.
	case "$CURRENT_DIR" in
	*[\'\"\$\\\`#\(\)]*)
		tmux display-message "tmux-pane-status: unsupported characters in install path"
		return 0
		;;
	esac
	clear_hooks
	for module in $(get_tmux_option @pane-status-modules "$DEFAULT_MODULES"); do
		if [ "${module//[!a-z]/}" = "$module" ] && [ -r "$CURRENT_DIR/modules/$module/load.sh" ]; then
			# shellcheck source=/dev/null
			. "$CURRENT_DIR/modules/$module/load.sh"
		else
			tmux display-message "tmux-pane-status: unknown module: $module"
		fi
	done
	update_formats
	bind_tree_keys
}

main
