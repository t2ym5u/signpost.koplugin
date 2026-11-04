# Changelog

All notable changes to this project will be documented in this file.

## [1.1.0] - 2026-11-04

### Changed
- 7×7 Hard puzzles build about twice as fast (up to 0.26 s on a desktop,
  now 0.15 s): the one-step trials no longer try the same links twice.
  Same puzzles as before.
- A "Generating puzzle…" progress bar shows when a puzzle takes more than a
  moment. Needs game-common 1.12.0.

## [1.0.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.0.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.0.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.0.0] - 2026-10-30

### Added
- First release: Signpost on 4×4 to 7×7 grids, Easy / Medium / Hard.
- Generator with a tiered deductive solver; every puzzle has exactly one
  solution, checked again by an exhaustive count before it is shown.
- Tap a cell, then a cell along its arrow, to link them; chains are labelled
  with numbers or letters as in the original. Hold a cell to cut its links.
- Hint (two taps), Undo, Clear, Show / Hide solution, timer, auto-save.
- English, French, Spanish and German strings.
