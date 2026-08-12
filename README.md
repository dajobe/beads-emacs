# bv-emacs

`bv-emacs` is an Emacs 29+ interface to
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
(add-to-list 'load-path "/path/to/bv-emacs")
(require 'bv)
```

With `use-package`:

```emacs-lisp
(use-package bv
  :load-path "/path/to/bv-emacs"
  :commands (bv bv-menu bv-ready bv-triage))
```

You can byte-compile and install the package under
`~/.emacs.d/site-lisp/bv-emacs` with:

```console
make install
```

Add that directory to `load-path` before requiring `bv`. Override the
destination with `make install PREFIX=/another/prefix` or `make install
INSTALL_DIR=/exact/directory`.

## Getting started

1. Visit any file inside a repository containing `.beads` or `_beads`.
2. Run `M-x bv` to open the main issue list.
3. Press `RET` on an issue to open its detail buffer.
4. Press `?` or run `M-x bv-menu` for the menu of lists, analysis, and
   mutations.

The package runs list, detail, and analysis reads asynchronously and preserves
the selected issue when a view refreshes. Commands are scoped to the workspace
shown in the buffer, so buffers from different repositories do not share
results.

## Main commands

| Command               | Purpose                                    |
|:----------------------|:-------------------------------------------|
| `M-x bv`              | Open the main issue list                   |
| `M-x bv-list-ready`   | List issues with no blockers               |
| `M-x bv-list-blocked` | List blocked issues                        |
| `M-x bv-list-search`  | Search issues in the current workspace     |
| `M-x bv-show`         | Open an issue by ID                        |
| `M-x bv-triage`       | Show graph-aware triage recommendations    |
| `M-x bv-next`         | Show the single top recommendation         |
| `M-x bv-plan`         | Show parallel dependency-aware work tracks |
| `M-x bv-check`        | Check the workspace and tool versions      |
| `M-x bv-menu`         | Open the discoverable command menu         |

The shorter `bv-ready`, `bv-blocked`, and `bv-search` commands are aliases for
their corresponding `bv-list-*` commands. `bv-transient` is an alias for
`bv-menu`.

List and detail buffers display their available bindings through `C-h m`. Common
navigation follows normal Emacs conventions: `RET` visits the issue at point,
`g` refreshes the current view, and `q` quits the window.

## Customization

Run `M-x customize-group RET bv RET` to see all options. The primary options
are:

- `bv-br-executable`: executable name or path for `br`.
- `bv-bv-executable`: executable name or path for `bv`.
- `bv-default-workspace`: fallback workspace when the current buffer is not
  inside one.
- `bv-database-file`: optional database passed to Beads commands.
- `bv-error-buffer-name`: buffer used for retained command diagnostics.

For example:

```emacs-lisp
(setq bv-br-executable "/opt/homebrew/bin/br"
      bv-bv-executable "/opt/homebrew/bin/bv"
      bv-default-workspace "~/src/project/")
```

Executable options must name programs Emacs can run. If `br` and `bv` work in a
terminal but not in Emacs, update `exec-path` or use absolute paths.

## Workspace selection

Workspace selection uses the buffer-local `bv-workspace` first, then an explicit
command argument, `bv-default-workspace`, and finally the nearest parent
containing `.beads` or `_beads`. Set `bv-workspace` locally when one buffer
should target another repository.

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

`bv-emacs` is free software licensed under the GNU General Public License,
version 3 or (at your option) any later version. See [LICENSE](LICENSE).
