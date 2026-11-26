# Recipes

Scripts to copy and edit, built on the plugin's public interfaces only: pane
options, `pane-status list` and notifications (see the
[README](../../README.md)). They are not part of the plugin and are not kept
compatible: copy them rather than sourcing them from the plugin directory.

Each recipe starts with a comment that names the schema it needs, what it
depends on and how to install it. Scripts call the CLI as `pane-status`, so
put it on your `PATH` first ([Quick start](../../README.md#quick-start)).

`tests/run.sh` runs every recipe. A recipe that cannot
be written without the plugin's internals points to something missing from the
interfaces: please open an issue.
