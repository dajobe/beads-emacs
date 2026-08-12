# Architecture

## Purpose

`beads-emacs` is an Emacs 29+ interface to the Beads tools. `br` owns issue
storage and mutations; `bv` supplies graph-aware analysis and triage. The
package does not edit Beads JSONL or SQLite data directly.

## Package layout

- `beads-core.el` discovers workspaces, runs commands, decodes JSON, and reports
  subprocess failures.
- `beads-list.el` provides tabulated issue, ready, blocked, and search views.
- `beads-show.el` renders a navigable issue detail buffer.
- `beads-triage.el` renders `bv` triage and planning results.
- `beads-edit.el` implements create, update, claim, close, reopen, defer,
  comment, label, and dependency workflows.
- `beads-transient.el` provides the discoverable command menu.
- `beads.el` is the package entry point and public `M-x beads` command. `M-x bv`
  is its short alias.

Every package symbol uses the `beads-` prefix, except the intentional short `bv`
command alias for `beads`. Files may depend on `beads-core`, but the core layer
must not depend on a user-interface module.

## Command boundary

Commands are passed as argument lists to `make-process` or `process-file`. Shell
command strings and direct execution of command text returned by `bv` are
forbidden. Executable command names are resolved only through `exec-path`;
absolute and relative paths are rejected. `default-directory` is the workspace
root. Read commands always request JSON:

- `br list --json`, `br ready --json`, `br blocked --json`, `br show ID --json`,
  and `br search QUERY --json` provide issue data.
- `bv --robot-triage --brief --format json`, `bv --robot-next --format json`,
  and `bv --robot-plan --format json` provide analysis.

Only `br` performs normal mutations. Successful writes refresh affected buffers.
Destructive or state-ending actions require confirmation. Standard error
handling retains stderr, the exit status, the executable, and arguments; it
never replaces a successfully rendered buffer with partial output.

JSON decoders tolerate additional object fields. They validate only the fields
needed by the current view and normalize both symbol-keyed and string-keyed
objects at the package boundary. The list command's `issues` envelope and the
show command's single-element array are handled explicitly.

## Workspace model

The current workspace is determined in this order:

1. The buffer-local `beads-workspace` value.
2. An explicit directory supplied to the command.
3. The customizable `beads-default-workspace` value.
4. The nearest parent directory containing `.beads` or `_beads`.

The selected path is normalized to the repository root. Commands pass the
workspace directory through `default-directory`; an explicit database setting is
passed with `--db`. Buffers include the root in their identity so separate
repositories never share stale data.

## User interface

`M-x beads` opens the main issue list. It derives from `tabulated-list-mode`,
preserves the selected issue across refreshes, and initially shows priority,
status, type, ID, title, and assignee. Ready, blocked, all, and search views use
the same renderer.

`RET` opens an issue detail buffer derived from `special-mode`. Dependencies and
issue identifiers are buttons. Analysis commands use read-only `special-mode`
buffers. The transient menu and menu bar expose commands without requiring users
to memorize keys.

Mutations use minibuffer prompts with completion over known domain values.
Create and edit operations collect text without constructing a shell command.
Claim uses the atomic `br update ID --claim --json` operation. Close prompts for
a reason and confirmation.

## Refresh and concurrency

Interactive reads run asynchronously. Each buffer owns at most one active
request; a newer refresh supersedes the older request, and stale sentinels may
not update the buffer. A visible header or mode-line indicator shows active
work. Killing a buffer stops its owned process.

List, detail, and analysis buffers watch `issues.jsonl` or legacy `beads.jsonl`
directly, falling back to the owning Beads data directory until the file exists.
This works with notification backends such as macOS kqueue that do not report
file-content changes through directory watches. Events are debounced and refresh
only visible, idle buffers. A replaced file is watched again automatically.
Killing or repurposing a buffer removes its watch and pending timer. When file
notifications are unavailable, manual `g` refresh remains available.

The core runner is replaceable in tests. Rendering and command construction
remain pure enough for ERT tests to cover them without installed binaries.

## Compatibility and quality

The package declares Emacs 29.1 as its minimum and uses only bundled libraries,
including `json`, `map`, `seq`, `subr-x`, `tabulated-list`, and `transient`.
Quality gates include byte compilation, Checkdoc, package-lint when installed,
ERT, a temporary-workspace smoke test, Markdown formatting, and whitespace
validation with `git diff --check`.
