# Hokusai examples

Runnable demos for [Hokusai](https://github.com/ivantokar/hokusai), a Swift library for server-side image processing built on libvips. Open an image, build an ordered pipeline, see the result, and copy the Swift that reproduces it. Documentation: <https://ivantokar.com/oss/hokusai/>.

| What | Where | Status |
| --- | --- | --- |
| Web playground served by a **Vapor** backend ([Hokusai Vapor](https://github.com/ivantokar/hokusai-vapor)) | [`vapor-server/`](vapor-server) | works |
| The same playground served by a **Hummingbird** backend ([Hokusai Hummingbird](https://github.com/ivantokar/hokusai-hummingbird)) | [`hummingbird-server/`](hummingbird-server) | works |
| Shared recipes, operation catalog, Swift code generator, bounded upload store | [`recipes/`](recipes) | works |
| Native macOS playground (SwiftUI, offline, no server) | [`macos/`](macos) | works |
| Inspect view (source facts and metadata verified on exported bytes) | web | works |
| Runtime Lab (streaming, cancel, queue limits, failure examples) | web | works |
| Export / PDF view (encoder comparison, raster PDF report, HokusaiPDF document builder) | web | works |

Both backends serve **one** web UI and answer the **same** HTTP API, so you can compare how each integration behaves. The active backend is shown in the top bar.

## Try it

### Docker (Linux, libvips 8.16 built from source)

```sh
docker compose up vapor          # http://localhost:8081
docker compose up hummingbird    # http://localhost:8082
```

Both can run together; they publish different ports. The first build compiles libvips and takes a few minutes. The image reports what it can really do at `/api/capabilities`; codec support is never assumed from the image name.

### Natively on macOS

```sh
brew install vips cairo pango pkg-config
cd vapor-server && swift run App          # http://127.0.0.1:8081
cd hummingbird-server && swift run App    # http://127.0.0.1:8082
```

Needs Swift 6.0+ and libvips 8.16+. Environment variables: `PORT`, `HOST`, `WEB_ROOT` (default `../web`), `FIXTURES_ROOT` (default `../fixtures`), `HOKUSAI_MAX_CONCURRENT` (default 2) and `HOKUSAI_MAX_QUEUED` (default 2). The two Hokusai limits are small on purpose, so the Runtime Lab can show a queue filling and rejecting; Hokusai freezes them at the first image, so change them by restarting.

### The macOS app

A native SwiftUI app that runs Hokusai locally through the public API: offline, no Docker, no server.

```sh
brew install vips cairo pango pkg-config
cd macos && swift run MacPlayground      # or open macos/Package.swift in Xcode and run the MacPlayground scheme
```

Open or drop an image, pick a sample or a recipe, add, reorder, disable and edit steps in the sidebar and inspector, compare with the original, and copy or export. It uses the same recipe model, catalog and code generator as the Web demo (`recipes/`), so a recipe means the same thing in both. Undo and redo, per-step reset and disable, and the original comparison never touch your file. Evaluation runs off the main actor, edits are debounced and superseded work is cancelled, and a result is published only if it belongs to the newest edit; if an edit fails, the last good image stays on screen with the error beside it. The reduced preview never reaches the Swift you copy or the export.

It is a Swift package, not a signed `.app`: a redistributable app needs a decision on bundling and signing the native libraries, which is out of scope here (it links the Homebrew libvips).

### The minimal integration

Each server has one self-contained route you can read without the demo around it: upload → resize → response.

```sh
curl --data-binary @photo.jpg 'http://localhost:8081/api/minimal/resize?width=800' -o small.webp
```

It is ten lines in [`vapor-server/Sources/App/main.swift`](vapor-server/Sources/App/main.swift) (`minimalRoutes`) and in [`hummingbird-server/Sources/App/main.swift`](hummingbird-server/Sources/App/main.swift).

## How it is built

- A **recipe** is an application-owned, versioned description of ordered steps plus an output setting. It is plain JSON, compiles into ordinary public Hokusai calls, and never serialises Hokusai's own plan. Repeated steps and their order are kept.
- The **catalog** (`recipes/Sources/HokusaiRecipes/Catalog.swift`) defines every operation once: its public API mapping, description, parameters with units, defaults and ranges, how to apply it and how to print it as Swift. The web UI is generated from `GET /api/catalog`.
- The **servers** only adapt HTTP. Evaluation, the upload store and the JSON answers live in `HokusaiDemoServices` and are shared.
- **Preview** is Hokusai output from the server. The recipe always runs on the full original; the preview only shrinks the *result* for display, so crop and text stay exact. **Full size** and **Export** render the real result.
- **Uploads** are held in memory with a size limit, a total budget, a count limit and a 10-minute lifetime. An upload id is a random token, never a path.
- The code panel shows Swift for Hokusai alone, or inside a Vapor or Hummingbird route. A placeholder (`input.jpg`) stands in for your file; it never contains a server path.

### HTTP API

| Request | Answer |
| --- | --- |
| `GET /api/backend` | which backend answered, Hokusai version |
| `GET /api/catalog` | operations, outputs, presets, samples |
| `GET /api/capabilities` | libvips and Cairo versions, readable and writable formats |
| `GET /api/status` | running and queued evaluations, the frozen runtime configuration, stored uploads |
| `POST /api/uploads` (raw body) | `{ uploadId, width, height, orientedWidth, … }` |
| `POST /api/render` `{ uploadId, recipe, previewMaxEdge?, stopBefore?, viewable? }` | the encoded image; `X-Hokusai-*` and `Server-Timing` headers. `stopBefore` (a step id) renders only the steps before it: the image a crop enters |
| `POST /api/pdf` `{ uploadId?, document, previewPage? }` | a vector PDF built with HokusaiPDF, or a PNG of one page decoded from it; `X-Hokusai-Pdf-Pages`, `X-Hokusai-Selectable-Text` |
| `POST /api/compare` `{ uploadId, recipe }` | the recipe through every encoder this runtime has: size, dimensions, time, or the reason one is missing |
| `POST /api/inspect` `{ uploadId, recipe? }` | facts about the original and, with a recipe, about the bytes it exports, read back |
| `POST /api/code` `{ recipe, target }` | `{ code }` |
| `POST /api/minimal/resize?width=` (raw body) | the minimal integration |

Errors are `{ "error": { "code", "message" } }` with a status you can act on: 404 expired upload, 413 too large, 422 not an image or a recipe that cannot apply (for example a crop outside the image).

## Capability coverage

[`coverage/COVERAGE.md`](coverage/COVERAGE.md) maps every current public capability to where the demo shows it, and says honestly what is implemented, partial or still planned. CI regenerates it from [`coverage/coverage.json`](coverage/coverage.json) and fails if the catalog and the matrix disagree.

## Checks

```sh
swift test --package-path recipes      # catalog, compiler, code generator, upload store
swift test --package-path macos        # the macOS app's model: undo/redo, revision gating, preview vs export
scripts/check-snippets.sh              # the Swift the playground prints compiles and runs, for every preset and the PDF template
scripts/coverage.py --check            # the coverage matrix is current
scripts/smoke.sh http://127.0.0.1:8081 vapor   # HTTP smoke test against a running backend
```

CI builds both Docker images, starts each and runs the same smoke test; a macOS job runs the rest and both servers natively.

## Testing unreleased library changes

The packages depend on released versions and commit their resolved dependencies. To try local changes to a library, check it out next to this repository and use SwiftPM's edit mode in the package you are running:

```sh
cd vapor-server
swift package edit hokusai --path ../../hokusai          # or hokusai-vapor
swift run App
swift package unedit hokusai                             # restore the released version
```

Never commit an edited checkout.

## Known limitations

- Measured by the Runtime Lab on both backends: aborting a `/api/render` request in the browser does not stop the evaluation on the server; it finishes the work first. Treat browser-side cancellation as not proving native cancellation.

- macOS: no on-canvas crop yet, and the window UI has been built and its model tested but not driven by an automated UI test.
- Image layers and masks, split compare, and switching between two running backends are planned. The macOS app has numeric crop only and no vector document builder yet (its output panel does offer the raster PDF and every encoder).
- Vector documents: pictures come from the bundled samples or your upload; there is no font upload, so text uses the system's sans, serif and monospace. The "selectable text" indicator in the Web UI is a heuristic (the PDF carries a text font with a character map); the unit tests confirm it with a real PDF reader on macOS.
- Browsers do not display TIFF, HEIF or PDF as images, so the playground shows a labelled PNG decoded from the real bytes; Export always downloads the real file.
- The playground previews at 1280 px; there is no downsampled-input fast path yet, because it is not equivalent for blur, trim, text and geometry steps.
- Multi-architecture images are not claimed: build and test on the architecture you run.
- Fonts: the Docker image bundles DejaVu (free licence) for text; native runs use your system fonts.
- Vector PDF cancellation, memory and blocking-I/O limits are tracked in the Hokusai repository (#158 to #160) and will be shown, not hidden, when the PDF view lands.

## Related

[Hokusai](https://github.com/ivantokar/hokusai) · [Hokusai Vapor](https://github.com/ivantokar/hokusai-vapor) · [Hokusai Hummingbird](https://github.com/ivantokar/hokusai-hummingbird) · [Documentation](https://ivantokar.com/oss/hokusai/) · the archived [Vapor example](https://github.com/ivantokar/hokusai-vapor-example) is reference material only.

MIT licensed, see [LICENSE](LICENSE). Sample images in `fixtures/` are generated for this project.
