# Images as annotations

## Why

Comparing data across two pages means two screenshots that belong in one marked-up image. Today
the annotation editor rejects a dropped image and ignores ⌘V, so there is no way to bring the
second screenshot in. The goal: drop or paste another screenshot into the editor, have the canvas
make room for it, and treat it like any other annotation.

## Goals

- Drag an image onto the annotation editor, or press ⌘V with an image on the clipboard, and it
  becomes an **image shape** in the open document.
- The image shape can be selected, moved, scaled (always keeping its proportions), rotated,
  deleted and undone like every other shape.
- Annotations drawn over it sit on top of it, including blur, pixelate, the highlighter and the
  spotlight, in both the editor and the export.
- The canvas grows to hold it, through the existing `AnnotationCanvasGrowth`.
- It survives save and reopen: the `.screendrop` sidecar reopens with the image still a separate,
  movable shape.

## Non-goals

- Copying and pasting existing annotations (the editor has no shape clipboard today).
- Cropping the pasted image, or giving it its own border, shadow or corner radius.
- Dragging captures out of the Library grid (the grid has no drag source today). Library → Copy
  followed by ⌘V in the editor covers this.
- Images in the Recording Studio overlay canvas.
- Layering an image above other annotations.

## Anti-goals (would count as failure even if it technically works)

- The original screenshot losing resolution or shifting position in the export.
- Image pixels embedded in the sidecar JSON (it is decoded on every load and would bloat memory;
  see AGENTS.md → Memory).
- A pasted image that looks right in the editor but different in the export, or the other way round.

## Approaches considered

1. **Image shape (chosen).** A new `AnnoShapeKind` case. It inherits selection, transform,
   undo, z-order and canvas growth from the engine. It is the only option where the second image
   stays movable. Cost: it touches the shape model, the renderers, storage and the editor input.
2. **Stitch on drop.** Join the two images into a new base image. This is cheap, and blur works
   with no changes, but the result can't be moved afterwards. Rejected.
3. **Layout mode** (arrange screenshots first, then annotate). This is a separate feature and
   still doesn't give a movable object. Rejected.

## Design

### Shape model (`Engine/Shape.swift`)

- `case image(ImageProps)` with `ImageProps { asset: String; w: Double; h: Double }`. `asset` is
  the stored file name (see Storage). `w`/`h` are page units, initially the image's pixel size.
- `isFilled` is true: a click anywhere on it grabs it with the select tool. Drawing tools draw over
  it as usual.
- `tool`/`swatch`/`strokeWidth`: no swatch and no stroke. `tool` needs a value. Add an
  `AnnotationTool` case only if the inspector needs one; otherwise map it to `.select` or an
  equivalent. Builder's call.
- Geometry: `Rectangle2d(w, h, isFilled: true)`.
- Every exhaustive `switch` over `AnnoShapeKind` gets a case. The compiler finds them:
  `AnnotationEditorModel.scaleShapeContents` (scales `w`/`h` like a redaction, which keeps a crop
  consistent), `AnnoEditorInteraction.applyScale`, `AnnoShapeGeometry.build`,
  `AnnoShapeRenderer.elements`, `AnnotationCanvasGrowth.extents`, `AnnotationTool`,
  `AnnotationToolDock`, `AnnoShapeDrawing`.

### Proportions

An image always scales uniformly:

- Selected alone, it shows corner handles only (no side handles), and corner drags behave as if
  Shift were held.
- In a mixed selection, the image takes the average of the two scale factors, the way a numbered
  callout does (`applyScale`), so it never distorts.

### Rendering and z-order (`Engine/AnnoShapeDrawing.swift`, `Engine/ShapeRenderer.swift`)

- New `RenderElement.Content.image(ImageProps)`. `drawShape` draws the decoded `CGImage` into
  `0,0,w,h` in the shape's local space, handling the flipped canvas context the way redactions
  already do. Opacity applies as for other shapes.
- **Images get their own first pass**, before the highlighter, redactions and spotlight, in
  document order among themselves. So every annotation lands on top of an image, whenever it was
  drawn. That matches "put stuff on top of it", and is why images never layer above annotations.
- **Export** (`AnnotationRenderer.drawAnnotations`): redactions there sample the composed context,
  so they already pick up an image drawn in the earlier pass. The highlighter blends against the
  context, so it works too. Check both.
- **Editor canvas** (`AnnoCanvasLayerView`): the redaction `sample` closure and the highlighter's
  `backdrop` read only the base screenshot (and `surround` for the grown fill). Over an image they
  would show the wrong pixels. Both must take image shapes into account so the preview matches the
  export. A blur over a pasted image must visibly blur that image in the editor. **This is the part
  most likely to go wrong; verify it by eye.**
- `AnnotationCanvasGrowth.extents`: an `.image` element contributes its local rect as ink, so the
  canvas grows around it exactly as for a filled rectangle.

### Image loading and memory

- A nonisolated, thread-safe cache keyed by asset name, readable from the off-main export. The
  export decodes at full resolution. The editor may use a downscaled copy above a size threshold,
  the way `previewCGImage` handles the base image. Release the cache with the editor's other
  resources (`releaseEditorResources`) and after export (`AnnotationRenderer.render`'s `defer`).
- A missing asset file in the editor draws a neutral placeholder rectangle at the shape's size,
  so the shape stays selectable and deletable. The export skips it. Builder's call on the exact
  look.

### Storage

- When an image is brought in, it is written once as PNG to an editor working folder (temporary,
  owned by the model and cleaned up like `ownedCropURLs`). The file name is a hash of the PNG
  bytes, so the same image pasted twice is stored once.
- `commitEdits` → `ScreenshotHistoryStore.commitAnnotations` copies the assets that the current
  shapes reference into a sibling folder, `<display image>.assets/`, as part of the same
  `ScreenshotEditFileTransaction`. Assets no longer referenced are removed.
- On load, the model resolves assets from that folder.
- Every place that deletes or resets a capture's edit files also handles the folder:
  `removeAnnotations`, `delete(_:)`, and Library trash (`CaptureLibraryActions`). Search for
  `editDocumentURL(for:` to find them all.
- The sidecar `version` stays 2. Older builds that meet an unknown shape kind fail to decode
  `shapes`. That only affects downgrades, so it's acceptable. Builder's call on whether to make
  decoding tolerant per shape.

### Bringing an image in

- **Sources:** files dropped from Finder or a capture shelf card (`.draggable(item.url)`), and ⌘V
  with either image data (PNG/TIFF) or image file URLs on the pasteboard. Library → Copy writes
  file URLs, so it works through ⌘V.
- **Drop target:** the whole editor canvas area. Show the standard copy cursor while an image drag
  is over it. Non-image drags are still refused.
- **⌘V:** handled in `AnnotationKeyCommandHandlerView` only when not editing text (text editing
  keeps its normal paste) and not cropping. An empty or non-image pasteboard does nothing.
- **Placement:** beside the content, not at the cursor. The gap is
  `AnnotationCanvasGrowth.marginFraction` × the screenshot's shorter side. It goes on the side that
  keeps the combined result closest to square: wide screenshots stack the new image below
  (left-aligned), tall ones put it to the right (top-aligned). "The content" means the screenshot
  plus any image shapes already on that side, so a third drop goes after the second rather than on
  top of it.
- **Size:** placed at its own pixel size (screenshots from the same display then show text at the
  same size). It is scaled down only if needed to keep the grown canvas within
  `AnnotationCanvasGrowth.maximumCanvasDimension`.
- **After insertion:** the select tool is active, the new image is selected, the view refits so the
  grown canvas is visible, and the whole insertion (several files dropped at once included) is one
  undo step.

### Inspector

When an image is selected, the inspector shows only what applies to it (opacity, if the inspector
already offers it for shapes). There are no style controls. Builder's call on the details.

## Left to the builder

- Exact hook points for drop and paste in `AnnotationEditorWindow`/`AnnotationCanvas`.
- How the editor canvas composites images into the redaction and highlighter sampling.
- The cache's eviction policy and the downscale threshold.
- Placeholder look for a missing asset.

## Verification

There is no test target. The build must pass, then check by hand in `Screendrop Dev`:

- Drop from Finder, drop from the shelf, ⌘V from Preview, ⌘V after Library → Copy.
- The canvas grows. The new image is movable, keeps its proportions at every handle, rotates, and
  undo removes it in one step.
- A box, an arrow, text, blur, pixelate, the highlighter and the spotlight drawn over it look the
  same in the editor and the export.
- Save, close, reopen: the image is still a separate shape. Delete the capture from the Library:
  the `.assets` folder is gone.
- Crop the base screenshot with an image present: the image keeps its place relative to the
  screenshot.

## As built

Where the build settled something the design left open or got wrong:

- **Resizing a picture** follows the pointer along the dragged corner's diagonal, not the larger
  of the two axes. That way a straight sideways drag inward shrinks it (the larger-axis rule left
  it unchanged), and it never flips.
- **Placement** lives in `AnnotationImagePlacement.swift`, beside `AnnotationCanvasGrowth`, rather
  than in `Engine/`. The other engine check scripts compile `Engine/` without the growth code.
- **A drop activates the editor window**, so the first drag after dropping moves the picture
  instead of being spent on activating the window.
- **The spotlight** still dims only the screenshot itself, as before. A picture outside the
  screenshot isn't dimmed, in the editor or the export.
- **Hit testing** checks pictures last, since they're drawn beneath everything else.
- **A mixed selection** that holds a picture gets corner handles only and scales evenly as a
  whole. That replaces "the picture takes the average of the two factors" from Proportions above,
  because averaging still let the other shapes stretch around a picture that didn't.
- **Arrows don't bind to pictures.** The exporter draws arrows without their bindings (as it
  always has, for every shape), so a bound arrow would end in a different place in the export.

