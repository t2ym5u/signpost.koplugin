# Changelog

All notable changes to this project will be documented in this file.

## [1.3.0] - 2026-11-05

### Changed
- Hard no longer needs trial and error. It used to need one-step "what
  if" trials (assume a link, see it break), which is guessing. Hard now
  uses the same two kinds of reasoning as Medium, only much more of the
  number bookkeeping: on 100 grids per size, 3.4 such steps on average at
  5×5 (Medium: 1), 6.1 at 6×6 (Medium: 2.1), 10.6 at 7×7 (Medium: 5.5).
  Medium now has a ceiling on those steps, so the two levels no longer
  overlap. On 4×4 grids two such steps are rare, so 4×4 Hard is often
  like Medium.
- 7×7 Hard builds about twice as fast: under 0.05 s on a desktop (about
  1 s on a Kobo) at worst, from 0.09 s. 7×7 Medium, which now has to find
  a grid under its ceiling, can take as long (from 0.02 s); the progress
  bar shows meanwhile.
- Medium and Hard grids differ from those of earlier versions, so the
  Daily Challenge puzzle changes once for those levels.

## [1.2.1] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.2.0] - 2026-11-04

### Changed
- 7×7 Hard puzzles build two to four times faster: from up to about 0.2 s
  on a desktop (about 5 s on a Kobo) to under 0.1 s (about 2 s on a
  Kobo); 6×6 Hard from 0.1 s to under 0.04 s. When the builder adds a
  number to a grid it can't finish yet, the solver carries on from where
  it stopped instead of starting over, and checking which numbers can be
  taken back starts from those saved steps too. Same puzzles as before.
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

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
