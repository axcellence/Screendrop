# This fork

A personal fork of [fayazara/Screendrop](https://github.com/fayazara/Screendrop) with two additions
to the screenshot editor. Everything else is the original app.

## What is different

- **Hand-drawn shapes.** Rectangles, circles, lines and arrows are drawn as a single brush stroke
  with thick and thin parts and ends that overshoot, instead of a ruler-straight outline. The
  **Style** row in the inspector switches between Hand-drawn and Clean; hand-drawn is the default
  and the choice is remembered.
- **Highlighter** (`M`). A freehand marker that tints what it passes over and leaves the text
  readable, with a scalloped marker edge at each end. It keeps its own colour and size, apart from
  the pen's. The existing Highlight tool, which dims everything outside a region, is unchanged.

A screenshot that uses the highlighter will not reopen for editing in the official app; the
exported image is unaffected.

## How it is set up

- `main` mirrors the original. The fork's changes live on `personal`.
- Signed with the fork owner's team under its own bundle ID (`com.axcellence.Screendrop`), so its
  permissions and settings are separate from the official app's.
- The built-in updater is switched off (`UpdaterManager.followsOfficialReleases`). Its feed is the
  official one, and following it would replace this build with the official release.

## Install on a Mac

```bash
git clone -b personal https://github.com/axcellence/Screendrop.git
cd Screendrop
scripts/install-fork.sh
```

Needs Xcode 26.4 or newer, signed in to the team set in the project. The script builds a Release
copy and replaces `/Applications/Screendrop.app`.

## Pick up a new upstream release

```bash
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout personal && git rebase main
scripts/install-fork.sh
```

## Check the drawing code

There is no test target. The two features are covered by a standalone check that compiles the real
annotation engine; the command is in the header of `scripts/check-annotation-ink.swift`. Pass it a
directory to also write PNG contact sheets of every shape and stroke.
