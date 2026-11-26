# shellcheck shell=bash disable=SC2034
# Sourced by pane-status.tmux; it reads the variables set here.

GH_TICK="#('$CURRENT_DIR/modules/gh/gh-status' tick)"

gh_pr_state_icon() { icon gh-pr-state "$1" "$1"; }
gh_checks_icon() {
	case "$1" in
	failure) icon gh-checks "$1" '✗' ;;
	pending) icon gh-checks "$1" '…' ;;
	success) icon gh-checks "$1" '✓' ;;
	esac
}

GH_PR_STATE_ICON="$(chain "#{$OPT_GH_PR_STATE}" "$GH_PR_STATES" gh_pr_state_icon)"
GH_CHECKS_ICON="$(chain "#{$OPT_GH_CHECKS}" "$GH_CHECKS" gh_checks_icon)"
GH_FORMAT="###{$OPT_GH_PR_NUMBER} $GH_PR_STATE_ICON#{?#{$OPT_GH_CHECKS}, $GH_CHECKS_ICON,}"

interpolations+=(
	"#{gh_pr_number}" "#{$OPT_GH_PR_NUMBER}"
	"#{gh_pr_state}" "#{$OPT_GH_PR_STATE}"
	"#{gh_pr_state_icon}" "$GH_PR_STATE_ICON"
	"#{gh_checks}" "#{$OPT_GH_CHECKS}"
	"#{gh_checks_icon}" "$GH_CHECKS_ICON"
	"#{gh_status}" "#{?#{$OPT_GH_PR_STATE},$GH_FORMAT,}"
)
tree_pane="#{?#{$OPT_GH_PR_STATE},$(tree_item "$GH_FORMAT"),}"
tree_window="$tree_pane"

# choose-tree lists every pane, so one job refreshes them all.
gh_right="$(tmux show-option -gqv status-right)"
case "$gh_right" in
*"$GH_TICK"*) ;;
*) tmux set-option -g status-right "$gh_right$GH_TICK" ;;
esac
unset gh_right
