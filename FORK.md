# This fork

A personal fork of [fayazara/Screendrop](https://github.com/fayazara/Screendrop) with five additions
to the screenshot editor and more ways to bring an image into it. Everything else is the original
app.

## What is different

- **Hand-drawn shapes.** Rectangles, circles, lines and arrows are drawn as a single brush stroke
  with thick and thin parts and ends that overshoot, instead of a ruler-straight outline. The
  **Style** row in the inspector switches between Hand-drawn and Clean; hand-drawn is the default
  and the choice is remembered.
- **Highlighter** (`H`, or `M`). A freehand marker that tints what it passes over and leaves the text
  readable, with a scalloped marker edge at each end. It keeps its own colour and size, apart from
  the pen's. The existing Highlight tool, which dims everything outside a region, is unchanged.
  Select moves from `H` to `V` to make room.
- **Handwriting text.** A fourth font, Handwriting (Caveat, a marker hand), after the SF faces. It
  ships inside the app with its licence, so it looks the same on any Mac. Bold switches its weight;
  it has no italic. It is the default for new text and the choice is remembered.
- **Notes beside the screenshot.** Anything drawn past the screenshot's edge, such as an arrow out
  to a note, makes the canvas grow to hold it with a little room to spare, and the room goes again
  when the shape is moved back or deleted. With a background the background extends; without one
  the new space takes the screenshot's own edge colour (white when the edge is busy or
  see-through), and **Extra space** in the inspector picks another colour.
- **Annotate any image.** Besides Finder's Open With, an image can come in through **Open
  Image…** (`⌘O`), **Annotate Clipboard Image** (`⌘⇧V`, or `⌘V` in the Library), or by dropping it
  on the Library. Each adds a copy to the Library and leaves the original alone. A batch dropped on
  the Library is only added; everything else opens in the editor.
- **Another screenshot in the editor.** Drag an image onto the editor, or press `⌘V` with one on
  the clipboard, and it lands beside the screenshot as an object of its own, with the canvas
  growing to hold it. Move it, scale it from a corner (it keeps its proportions) and draw over it;
  blur, pixelate and the highlighter work on it too. Handy for comparing two pages in one marked-up
  image. It stays a separate object when the capture is reopened.

A screenshot that uses the highlighter, Handwriting text or another image will not reopen for
editing in the official app; the exported image is unaffected. A screenshot saved with notes
outside the image reopens there with the canvas back at the screenshot's size, so exporting it
again from the official app cuts those notes off.

## How it is set up

- `main` mirrors the original. The fork's changes live on `personal`.
- Signed with the fork owner's team under its own bundle ID (`com.axcellence.Screendrop`), so its
  permissions and settings are separate from the official app's.
- The built-in updater (Sparkle) follows this fork's own GitHub releases, not the official ones.
  Each release carries the app and its `appcast.xml`, and the app reads
  `https://github.com/axcellence/Screendrop/releases/latest/download/appcast.xml`. Updates are
  signed with the fork's own Sparkle key. Debug builds never check.

## Install on a Mac without Xcode

1. Download [Screendrop.zip](https://github.com/axcellence/Screendrop/releases/latest/download/Screendrop.zip)
   from the newest release on the [Releases page](https://github.com/axcellence/Screendrop/releases).
   Safari unzips it into `Downloads`.
2. Move `Screendrop.app` into the `Applications` folder inside your home folder (in Finder, Go ›
   Home; make a folder named `Applications` there if there is none), and open it from there.

From then on it updates itself. Turn on **Check for updates automatically** in Settings › About (it
may be off in settings carried over from an earlier copy) and it looks for releases in the
background and asks before installing one. Opening the Library also looks, and shows a blue arrow
button beside Settings when a release is waiting. **Check for Updates…** in the menu bar menu or in
Settings › About checks straight away. Sparkle replaces the app where it is, which is why it lives
in `~/Applications`: that needs no administrator password, while `/Applications` does. Do not run it
straight from `Downloads`, where macOS runs it from a read-only copy that cannot update.

Moving from a copy that was built here and AirDropped across: quit it, install as above, and delete
the old copy (or, if `/Applications` will not let you, leave it unopened). Settings and the capture
library carry over, since the bundle ID is the same. macOS asks for screen recording permission one
more time, because the release is signed with the Developer ID rather than the development
certificate; after that, updates keep the permission. Granting it is the one step that can need an
administrator: on a Mac where you are a standard user, macOS asks for an administrator's name and
password when you switch screen recording on, unless the organisation's device policy lets standard
users do it. It is the same prompt the first copy needed.

## Install from source

```bash
git clone -b personal https://github.com/axcellence/Screendrop.git
cd Screendrop
scripts/install-fork.sh
```

Needs Xcode 26.4 or newer, signed in to the team set in the project. The script builds a Release
copy and replaces `/Applications/Screendrop.app`. On its first run on a Mac it copies the official
app's settings across; the capture library is shared already. macOS will ask for screen recording
permission again, because it is a differently signed app.

A copy built this way carries upstream's plain build number (40, say), so it is offered the newest
fork release (40.1 and up) as an update. Accepting it swaps the source build for the release build.
Going back and forth between the two costs a screen recording prompt each time, because they are
signed differently.

## Release

From a clean checkout of the commit to release, pushed to `axcellence/Screendrop`:

```bash
scripts/release-fork.sh --notes "What changed, one line per point"
```

It builds a Release copy, signs it with the Developer ID certificate, has Apple notarize it (a few
minutes), staples the ticket, and publishes a GitHub release with `Screendrop.zip` and
`appcast.xml`. Installed copies pick it up on their next check. Nothing is committed, so it works
from any branch. `--notes` is optional; `--dry-run` runs the build and packaging without the
Developer ID, notarization or publishing. If a run fails part way, run it again: it continues the
same release.

Version numbers are set at build time and never committed. The project keeps upstream's numbers;
the nth fork release on upstream build B is build `B.n`, shown as `<upstream version>-fork.n`, with
the tag `fork-B.n`. For example, the first release on upstream 0.38.0 (build 40) is
`0.38.0-fork.1` (build 40.1). Sparkle compares build numbers part by part, so they only go up, also
when upstream moves to build 41.

The newest release is the one apps update to, so do not mark another release on this repository as
latest.

### One-time setup on the releasing Mac

- **Developer ID certificate.** A "Developer ID Application" certificate for team `VG74JMPJF4`, with
  its private key, in the login keychain. Only the account holder can create one: in Xcode,
  Settings › Accounts › Manage Certificates › + › Developer ID Application, or upload a certificate
  signing request at developer.apple.com › Certificates and open the downloaded certificate.
- **Notarization.** A `notarytool` keychain profile named `screendrop-fork-notary`, made from an App
  Store Connect API key:
  `xcrun notarytool store-credentials screendrop-fork-notary --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer>`.
  `SCREENDROP_NOTARY_PROFILE` picks another name.
- **Sparkle key.** The fork's EdDSA key, in the keychain under the account
  `com.axcellence.Screendrop` so it stays apart from any other app's Sparkle key. Its public half is
  `SUPublicEDKey` in `Screendrop/Info.plist`, and the script refuses to run if they differ. Sparkle's
  tools are in the build's `SourcePackages/artifacts/sparkle/Sparkle/bin`. Keep a backup
  (`generate_keys --account com.axcellence.Screendrop -x <file>`, stored somewhere safe): installed
  copies accept only updates signed with this key, so losing it means reinstalling by hand.
- **GitHub CLI** signed in with push access to `axcellence/Screendrop`.

The script checks all of these first and says which one is missing.

## Pick up a new upstream release

```bash
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout personal && git rebase main && git push --force-with-lease origin personal
scripts/release-fork.sh
```

The release carries the new upstream version to every Mac. `scripts/install-fork.sh` still builds
this Mac's copy from source, if that is how it is installed here.

## Check the drawing code

There is no test target. The drawing features are covered by a standalone check that compiles the real
annotation engine; the command is in the header of `scripts/check-annotation-ink.swift`. Pass it a
directory to also write PNG contact sheets of every shape and stroke, and of Handwriting text. The
growing canvas has its own check beside it, `scripts/check-canvas-growth.swift`, which renders real
exports.
