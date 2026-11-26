# tmux-pane-status recipe: auto-seen (part 1 of 2)
# Schema: pane options of schema 1. Needs: tmux 3.8, pane-status on PATH.
#
# Marks a pane seen when you switch to it. Part 2, on-change.d/auto-seen,
# covers a pane that changes while you are looking at it. Copy into tmux.conf.

# Filtered in tmux, so switching to a pane with nothing unseen forks nothing.
%hidden PS_UNSEEN="#{&&:#{session_attached},#{&&:#{@pane-status_agent_activity},#{!=:#{@pane-status_agent_seen},1}}}"
set-hook -g "session-window-changed[100]" "if-shell -F '$PS_UNSEEN' 'run-shell -b \"pane-status agent seen --pane #{pane_id}\"'"
set-hook -g "window-pane-changed[100]" "if-shell -F '$PS_UNSEEN' 'run-shell -b \"pane-status agent seen --pane #{pane_id}\"'"
set-hook -g "client-session-changed[100]" "if-shell -F '$PS_UNSEEN' 'run-shell -b \"pane-status agent seen --pane #{pane_id}\"'"
