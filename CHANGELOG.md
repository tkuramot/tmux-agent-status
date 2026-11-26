# Changelog

## 1.0.0

The plugin records state and no longer shows it.

- Breaking: removed the placeholders, icons, choose-tree format, key bindings
  and `status-right` job. Their replacements are in `docs/recipes/formats`.
- Breaking: one CLI, `bin/pane-status`, replaces `agent-status` and
  `gh-status`. Remove the old `agent-status` hook entries, then reinstall the
  agent hooks.
- Breaking: agent state is split into activity (`working`, `waiting`, `idle`,
  `error`), `since` and `seen`; `done` is gone, and adapter maps use
  activities. Removed `@pane-status-agent-auto-seen` (now the auto-seen
  recipe).
- Breaking: pull requests are recorded as separate fields (state, draft,
  review, checks, url) instead of one label. Checks are GitHub's own summary.
- Breaking: removed `@pane-status-modules` and `@pane-status-gh-ttl`; added
  `@pane-status-gh-interval`.
- Added `pane-status list` (JSON, schema 1), change notifications through
  `on-change.d`, and `pane-status refresh`.
- Pull requests are looked up by a background poller, one request per
  repository, and no longer depend on a status line being shown.
