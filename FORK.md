# This fork

A personal fork of [fayazara/Screendrop](https://github.com/fayazara/Screendrop) with four additions
to the screenshot editor. Everything else is the original app.

## What is different

- **Hand-drawn shapes.** Rectangles, circles, lines and arrows are drawn as a single brush stroke
  with thick and thin parts and ends that overshoot, instead of a ruler-straight outline. The
  **Style** row in the inspector switches between Hand-drawn and Clean; hand-drawn is the default
  and the choice is remembered.
- **Highlighter** (`M`). A freehand marker that tints what it passes over and leaves the text
  readable, with a scalloped marker edge at each end. It keeps its own colour and size, apart from
  the pen's. The existing Highlight tool, which dims everything outside a region, is unchanged.
- **Handwriting text.** A fourth font, Handwriting (Caveat, a marker hand), after the SF faces. It
  ships inside the app with its licence, so it looks the same on any Mac. Bold switches its weight;
  it has no italic. It is the default for new text and the choice is remembered.
- **Notes beside the screenshot.** Anything drawn past the screenshot's edge, such as an arrow out
  to a note, makes the canvas grow to hold it with a little room to spare, and the room goes again
  when the shape is moved back or deleted. With a background the background extends; without one
  the new space takes the screenshot's own edge colour (white when the edge is busy or
  see-through), and **Extra space** in the inspector picks another colour.

A screenshot that uses the highlighter or Handwriting text will not reopen for editing in the
official app; the exported image is unaffected. A screenshot saved with notes outside the image
reopens there with the canvas back at the screenshot's size, so exporting it again from the
official app cuts those notes off.

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
copy and replaces `/Applications/Screendrop.app`. On its first run on a Mac it copies the official
app's settings across; the capture library is shared already. macOS will ask for screen recording
permission again, because it is a differently signed app.

## Pick up a new upstream release

```bash
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout personal && git rebase main
scripts/install-fork.sh
```

## Check the drawing code

There is no test target. The drawing features are covered by a standalone check that compiles the real
annotation engine; the command is in the header of `scripts/check-annotation-ink.swift`. Pass it a
directory to also write PNG contact sheets of every shape and stroke, and of Handwriting text. The
growing canvas has its own check beside it, `scripts/check-canvas-growth.swift`, which renders real
exports.
