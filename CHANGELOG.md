# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.2] - 2026-08-18

### Fixed

- Reserved a safety column so end-of-line markers and window dividers do not
  overwrite the final relative-age character in list rows.

## [0.1.1] - 2026-08-18

### Changed

- Renamed the Emacs package, features, modules, commands, customization group,
  variables, and installation directory to `beads`; retained `M-x bv` as a short
  alias for `M-x beads`.

### Fixed

- Fixed narrow list rows so relative creation ages remain visible in
  horizontally split Emacs windows.
- Required `br` and `bv` executable names to resolve through `exec-path` instead
  of accepting absolute or relative paths.
- Made the help popup context-sensitive and kept it aligned with every direct
  binding in list, issue-detail, and analysis buffers.

### Added

- Added responsive issue rows with type icons, compact states, titles, and
  right-aligned relative creation times.
- Added in-place All, Open, Closed, Ready, Blocked, label, and search list
  filters matching the main `bv` filtering keys.
- Added issue ID and title completion to interactive `beads-show` selection.
- Added visual word wrapping to `beads-show` detail buffers.
- Added debounced automatic refresh after external Beads JSONL changes.
- Added the initial Emacs 29+ interface to `br` and `bv`.
- Added asynchronous issue lists, issue details, triage, planning, and mutation
  workflows.
- Added byte-compilation, ERT, Checkdoc, optional package-lint, and Emacs 29/30
  continuous integration.
- Added installation, customization, architecture, and contribution
  documentation.
