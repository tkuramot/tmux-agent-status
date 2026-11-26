# tmux-pane-status recipe: formats
# Schema: pane options of schema 1. Needs: tmux 3.8.
#
# Shows the agent state and the pull request in the window list, pane borders
# and choose-tree, using the plugin's 0.x labels. Copy into tmux.conf, below
# any theme, and edit.

# A pane's agent state; "done" is an idle agent you have not looked at.
%hidden PS_PANE="#{?#{&&:#{==:#{@pane-status_agent_activity},idle},#{!=:#{@pane-status_agent_seen},1}},done,#{@pane-status_agent_activity}}"

# A window's most urgent pane state.
%hidden PS_PANES="#{P:$PS_PANE }"
%hidden PS_WINDOW="#{?#{m:*waiting*,$PS_PANES},waiting,#{?#{m:*error*,$PS_PANES},error,#{?#{m:*working*,$PS_PANES},working,#{?#{m:*done*,$PS_PANES},done,#{?#{m:*idle*,$PS_PANES},idle,}}}}}"

# The pull request, e.g. "#42 review ✗". Checks are shown for open ones.
%hidden PS_PR_LABEL="#{?#{!=:#{@pane-status_pr_state},open},#{@pane-status_pr_state},#{?#{==:#{@pane-status_pr_draft},1},draft,#{?#{==:#{@pane-status_pr_review},approved},approved,#{?#{==:#{@pane-status_pr_review},changes_requested},changes,review}}}}"
%hidden PS_PR_CHECKS="#{?#{==:#{@pane-status_pr_state},open},#{?#{==:#{@pane-status_pr_checks},failure}, ✗,#{?#{==:#{@pane-status_pr_checks},pending}, …,#{?#{==:#{@pane-status_pr_checks},success}, ✓,}}},}"
%hidden PS_PR="#{?#{@pane-status_pr_number},###{@pane-status_pr_number} $PS_PR_LABEL$PS_PR_CHECKS,}"

# Window list: the window's state, then its active pane's pull request.
set -g window-status-format "#I #W#{?$PS_WINDOW, ($PS_WINDOW),}#{?$PS_PR, $PS_PR,}"
set -g window-status-current-format "#I #W#{?$PS_WINDOW, ($PS_WINDOW),}#{?$PS_PR, $PS_PR,}"

# Pane borders: each pane's own state.
set -g pane-border-status top
set -g pane-border-format " #{?$PS_PANE,($PS_PANE) ,}#{?$PS_PR,$PS_PR ,}"

# choose-tree: the state after each window and pane.
%hidden PS_TREE="#{?pane_format,$PS_PANE,#{?window_format,$PS_WINDOW,}}"
%hidden PS_TREE_FORMAT="#{?pane_format,#{pane_current_command},#{?window_format,#{window_name},#{session_windows} windows}}#{?$PS_TREE, ($PS_TREE),}#{?#{||:#{pane_format},#{window_format}},#{?$PS_PR, $PS_PR,},}"
bind-key s choose-tree -Zs -F "$PS_TREE_FORMAT"
bind-key w choose-tree -Zw -F "$PS_TREE_FORMAT"
