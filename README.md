# beads-emacs

`beads-emacs` is an Emacs 29+ interface to
[Beads Rust (`br`)](https://github.com/Dicklesworthstone/beads_rust) and
[Beads Viewer (`bv`)](https://github.com/Dicklesworthstone/beads_viewer). It
keeps issue storage and mutations in `br` while using the graph-aware `bv` robot
commands for triage and planning.

The package provides tabulated issue lists, navigable issue details,
dependency-aware triage, and guided editing commands without reading or writing
Beads data files directly.

## Requirements

- Emacs 29.1 or newer.
- `br` and `bv` installed and available on `exec-path`.
- A Beads workspace containing a `.beads` or `_beads` directory.

The package uses only libraries bundled with Emacs. It is developed against `br`
0.2.22 and `bv` 0.19.0; its JSON readers tolerate additional fields from
compatible releases.

## Installation

### From a checkout

Clone this repository, then add it to `load-path`:

```emacs-lisp
(add-to-list 'load-path "/path/to/beads-emacs")
(require 'beads)
```

With `use-package`:

```emacs-lisp
(use-package beads
  :load-path "/path/to/beads-emacs"
  :commands (beads bv beads-menu beads-ready beads-triage))
```

You can byte-compile and install the package under `~/.emacs.d/site-lisp/beads`
with:

```console
make install
```

Add that directory to `load-path` before requiring `beads`. Override the
destination with `make install PREFIX=/another/prefix` or `make install
INSTALL_DIR=/exact/directory`.

## Getting started

1. Visit any file inside a repository containing `.beads` or `_beads`.
2. Run `M-x beads` to open the main issue list. `M-x bv` is a shorter alias.
3. Press `RET` on an issue to open its detail buffer.
4. Press `?` or run `M-x beads-menu` for the menu of lists, analysis, and
   mutations.

The package runs list, detail, and analysis reads asynchronously and preserves
the selected issue when a view refreshes. Commands are scoped to the workspace
shown in the buffer, so buffers from different repositories do not share
results. Visible Beads buffers also watch the workspace JSONL export and
automatically refresh after debounced external changes.

Issue rows prioritize the type icon, priority, compact state, ID, and title.
Their creation age stays aligned at the right edge so recent work remains easy
to spot without requiring rigid, wide columns.

## Main commands

| Command                  | Purpose                                    |
|:-------------------------|:-------------------------------------------|
| `M-x beads`              | Open the main issue list                   |
| `M-x bv`                 | Alias for `M-x beads`                      |
| `M-x beads-list-open`    | List open issues                           |
| `M-x beads-list-closed`  | List closed issues                         |
| `M-x beads-list-ready`   | List issues with no blockers               |
| `M-x beads-list-blocked` | List blocked issues                        |
| `M-x beads-list-label`   | Filter issues by label                     |
| `M-x beads-list-search`  | Search issues in the current workspace     |
| `M-x beads-show`         | Open an issue by ID                        |
| `M-x beads-triage`       | Show graph-aware triage recommendations    |
| `M-x beads-next`         | Show the single top recommendation         |
| `M-x beads-plan`         | Show parallel dependency-aware work tracks |
| `M-x beads-check`        | Check the workspace and tool versions      |
| `M-x beads-menu`         | Open the discoverable command menu         |

The shorter `beads-ready`, `beads-blocked`, and `beads-search` commands are
aliases for their corresponding `beads-list-*` commands. `beads-transient` is an
alias for `beads-menu`. The `?` popup adapts to list, issue-detail, and analysis
buffers so its current-buffer section documents the bindings that work there.

List and detail buffers display their available bindings through `C-h m`. Common
navigation follows normal Emacs conventions: `RET` visits the issue at point,
`g` refreshes the current view, and `q` quits the window. In a list buffer, `a`,
`O`, `X`, `r`, and `b` switch the same buffer to All, Open, Closed, Ready, and
Blocked respectively. Lowercase `o` is also an Open alias, `c` creates an issue,
`l` filters by label, and `/` searches in place. The popup and direct list
bindings use the same `O`, `X`, and `c` shortcuts.

## Customization

Run `M-x customize-group RET beads RET` to see all options. The primary options
are:

- `beads-br-executable`: executable name or path for `br`.
- `beads-bv-executable`: executable name or path for `bv`.
- `beads-default-workspace`: fallback workspace when the current buffer is not
  inside one.
- `beads-database-file`: optional database passed to Beads commands.
- `beads-error-buffer-name`: buffer used for retained command diagnostics.
- `beads-auto-refresh-on-change`: whether visible Beads buffers watch for
  external JSONL changes.
- `beads-auto-refresh-delay`: debounce delay before an automatic refresh.

For example:

```emacs-lisp
(setq beads-br-executable "/opt/homebrew/bin/br"
      beads-bv-executable "/opt/homebrew/bin/bv"
      beads-default-workspace "~/src/project/")
```

Executable options must name programs Emacs can run. If `br` and `bv` work in a
terminal but not in Emacs, update `exec-path` or use absolute paths.

## Workspace selection

Workspace selection uses the buffer-local `beads-workspace` first, then an
explicit command argument, `beads-default-workspace`, and finally the nearest
parent containing `.beads` or `_beads`. Set `beads-workspace` locally when one
buffer should target another repository.

All normal mutations go through `br`; analysis uses only `bv --robot-*`
commands. The package never executes command strings returned by `bv` and never
edits Beads JSONL or SQLite files itself.

## Development

Run the complete local quality suite with:

```console
make check
```

Individual targets include `build`, `test`, `checkdoc`, and `lint`. The lint
target runs `package-lint` when it is installed and otherwise reports a skip.
Use `make install-pre-commit-hook` to install a repository-local hook that runs
the full suite before commits. See [Contributing](docs/contributing.md) and the
[architecture notes](docs/architecture.md) for details.

## License

`beads-emacs` is free software licensed under the GNU General Public License,
version 3 or (at your option) any later version. See [LICENSE](LICENSE).
