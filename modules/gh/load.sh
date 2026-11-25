# shellcheck shell=bash disable=SC2034
# Sourced by pane-status.tmux; it reads the variables set here.

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

GH_FORMAT="###{$OPT_GH_NUMBER} $(chain "#{$OPT_GH_STATE}" "$GH_STATES" gh_icon)\
#{?#{$OPT_GH_CHECKS}, $(chain "#{$OPT_GH_CHECKS}" "$GH_CHECKS" gh_icon),}"

interpolations+=(
	"#{gh_status}" "#{?#{$OPT_GH_STATE},$GH_FORMAT,}"
	"#{gh_state}" "#{$OPT_GH_STATE}"
	"#{gh_number}" "#{$OPT_GH_NUMBER}"
	"#{gh_checks}" "#{$OPT_GH_CHECKS}"
)
tree_pane="#{?#{$OPT_GH_STATE},$(tree_item "$GH_FORMAT"),}"
tree_window="$tree_pane"

# choose-tree lists every pane, so one job refreshes them all.
gh_right="$(tmux show-option -gqv status-right)"
case "$gh_right" in
*"$GH_TICK"*) ;;
*) tmux set-option -g status-right "$gh_right$GH_TICK" ;;
esac
unset gh_right
