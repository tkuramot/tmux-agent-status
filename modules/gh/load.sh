# shellcheck shell=bash
# Sourced by pane-status.tmux.

GH_TICK="#('$CURRENT_DIR/modules/gh/gh-status' tick)"

gh_default() {
	case "$1" in
	failure) printf '✗' ;;
	pending) printf '…' ;;
	success) printf '✓' ;;
	*) printf '%s' "$1" ;;
	esac
}
gh_icon() { icon gh "$1"; }

# gh_chain OPTION STATES RENDER
gh_chain() {
	local st out="" close=""
	for st in $2; do
		out="$out#{?#{==:#{$1},$st},$("$3" "$st"),"
		close="$close}"
	done
	printf '%s%s' "$out" "$close"
}

GH_FORMAT="###{$OPT_GH_NUMBER} $(gh_chain "$OPT_GH_STATE" "$GH_STATES" gh_icon)\
#{?#{$OPT_GH_CHECKS}, $(gh_chain "$OPT_GH_CHECKS" "$GH_CHECKS" gh_icon),}"

interpolations+=(
	"#{gh_status}" "#{?#{$OPT_GH_STATE},$GH_FORMAT,}"
	"#{gh_state}" "#{$OPT_GH_STATE}"
)
TREE_PANE="$TREE_PANE#{?#{$OPT_GH_STATE},$(tree_item "$GH_FORMAT"),}"
TREE_WINDOW="$TREE_WINDOW#{?#{$OPT_GH_STATE},$(tree_item "$GH_FORMAT"),}"

# choose-tree lists every pane, so one job refreshes them all.
gh_right="$(tmux show-option -gqv status-right)"
case "$gh_right" in
*"$GH_TICK"*) ;;
*) tmux set-option -g status-right "$gh_right$GH_TICK" ;;
esac
unset gh_right
