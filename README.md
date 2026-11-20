# Mac Utility Kit

Working name for an open-source macOS utility suite with its own interface. The current build has 102 tools across images, PDFs, media, files, macOS, and development.

- [Feature inventory](docs/feature-inventory.md) — 102 published tools and shared app behavior.
- [Open-source alternatives](docs/open-source-alternatives.md) — what existing projects cover and where a single-app replacement falls short.
- [Open-source reuse map](docs/reuse/README.md) — upstream candidates, licenses, and implementation gaps for each of the 102 tools.
- [Development plan and tool specifications](docs/plan/README.md) — release milestones, controls, outputs, and acceptance checks for all 102 tools.

## Run locally

On an Apple silicon Mac with macOS 15 or later and Xcode 26 or newer installed, run `./scripts/build-app.sh` and open `build/Mac Utility Kit.app`. Run `swift test` to check the workflow fixtures. The generated app is ad hoc signed for local use.


### Video compression engines

Compress Video defaults to the native macOS encoder for H.264 and HEVC in MP4, MOV, and M4V. Balanced keeps the source resolution. Advanced settings let you set a target video bitrate, cap the longest edge, or set a bitrate per audio track. Select an installed FFmpeg executable to use constant-quality (CRF) encoding or export VP9/Opus WebM when the required encoders are available. Preview a five-second sample with the same settings used for export. Review measured sizes and keep or discard each result that did not shrink without re-encoding. WebM uses square pixels and preserves the displayed proportions of anamorphic sources. FFmpeg preserves supported HDR transfer functions and bit depth, while HDR10 mastering-display and content-light metadata can be lost.

The quality and sizing controls are based on [HandBrake's constant-quality model](https://handbrake.fr/docs/en/latest/technical/video-cq-vs-abr.html), [its separate resolution settings](https://handbrake.fr/docs/en/latest/advanced/resizing-video.html), and [FFmpeg's encoder options](https://ffmpeg.org/ffmpeg-codecs.html). FFmpeg is user-supplied. Set `MAC_UTILITY_FFMPEG_TEST` to its executable path when running `swift test` to enable the integration fixture.

Resize Images also supports a user-installed ImageMagick 7 executable via **Choose ImageMagick…**. See the [implementation audit](docs/reuse/implementation-audit.md) for supported engine paths and how to run the upstream integration tests.


### Media tools

- **Record Screen** records a display, window, or single-display region with optional system and microphone audio. Set resolution and frame rate, then pause, resume, or stop from the menu bar.
- **Download Video** inspects a URL using a selected yt-dlp executable. Choose a stream and output format, then download with separate video, audio, and finishing progress and cancellation. Stream merging and conversion require FFmpeg.

- **Convert Video** converts to MP4, MOV, and M4V with AVFoundation. A user-selected FFmpeg adds WebM export and resolution and frame rate options. Passthrough requires streams compatible with the destination container. WebM results identify observed codecs and report dropped tracks.
- **Media Info** inspects streams locally and exports a JSON report. The native engine exports labeled sections, while the optional user-selected ffprobe exports its detailed stream metadata. The native frame-timing check samples five short windows across the track and labels the result as an observation.
- **Extract Audio** selects a track by language or number, previews a chosen source, and exports to M4A, WAV, or AIFF. Language selection matches each file independently and reports missing or ambiguous tracks. A user-selected FFmpeg adds MP3 and FLAC. Source track discovery uses AVFoundation. Passthrough is supported for AAC and ALAC tracks in M4A.

Set `MAC_UTILITY_FFPROBE_TEST` to a local ffprobe binary to exercise the external Media Info integration fixture.


- **Change Speed** adjusts video timing with optional pitch preservation. Choose a queued video to preview its adjusted speed and pitch before export. Pitch-preserving preview and export use AVFoundation. Changing pitch along with speed requires a selected FFmpeg executable for clips with audio.
- **Extract Frames** scrubs and previews source video, then exports selected timestamps or a fixed interval to PNG, JPEG, or HEIC. Fixed intervals start at the first visible video frame, and timestamps use the source timeline. It uses the video formats supported by AVFoundation.

- **Trim Video** previews an in/out range, re-encodes a precise MP4 cut, or copies video and audio streams to MKV at keyframe-aligned boundaries with selected FFmpeg and ffprobe executables.
- **Mute Video** previews the audio track list and removes selected tracks or all audio. It copies encoded video through AVFoundation when the chosen MOV, MP4, or M4V container supports the retained streams.

- **Resize Video** previews fit, fill, or stretch framing and exports aligned MP4 dimensions. Choose a preset from 480p through 2160p, a percentage, or exact dimensions with optional aspect lock.
- **Video to GIF** previews a clip sample and estimates its size, then uses a selected FFmpeg executable to export an animated GIF with width, frame rate, palette, dithering, and loop controls.

- **Crop & Rotate Video** uses draggable crop handles, aspect presets, exact coordinates, quarter-turn rotations, and mirroring. Preview the edited frame before exporting MP4.

- **Merge Videos** reorders clips, previews each cut with still frames and up to two seconds of playback on each side, and exports one MP4 or MOV. Normalize fits mixed clips to a common frame. Compatible clips can use passthrough, with control over whether to retain primary audio.

- **Replace Audio** replaces or mixes a selected soundtrack with the original. Set track gains, an offset, and a duration policy, and listen to a short preview before exporting MP4.
- **Burn In Subtitles** imports or edits SRT cues, shifts their timing, and previews subtitle styling on a selected video frame. MP4 export uses a selected FFmpeg build with libass.

- **Trim Audio** selects a sample-accurate range with a waveform, time fields, and a looping preview. Export WAV, AIFF, or M4A with optional fades, or preserve PCM samples in matching WAV or AIFF output.

- **Convert Audio** converts to M4A, WAV, AIFF, MP3, or FLAC with sample rate, channel, and format-specific options. MP3 and FLAC require a selected FFmpeg executable. Metadata transfer depends on the output format.

- **Record Audio** records from a selected microphone with a live meter and pause/resume. Save M4A, or save and send the recording to Transcribe.
- **Clean Up Audio** reduces noise and 50/60 Hz hum with a selected FFmpeg executable. Compare a level-matched sample, then export WAV or copy the video stream into an MKV with cleaned audio.

### Image tools

- **Watermark** adds text or a logo to images, selected PDF pages, and video time ranges. Set placement, tiling, opacity, scale, margin, and rotation. Video uses a selected FFmpeg executable. Marked PDF pages retain visible content and selectable source text where supported, with interactive objects flattened.
- **Color Picker** uses the macOS magnified sampler and shows sRGB HEX, RGB, and HSL. Choose a precision, copy a value, or revisit recent session swatches.
- **Annotate Screenshot** adds ordered arrows, lines, shapes, text, and numbered callouts. Open an image or hand off a capture from Screenshot, then copy or export a flattened PNG or JPEG.
- **Remove Background** detects foreground subjects locally, supports adjustable Keep and Remove brushes plus rectangular refinements, and exports transparent PNG or a solid-background PNG or JPEG.
- **Screenshot** captures a display, a window, a region, or a manually scrolled sequence. Review the image or stitching seams before copying or exporting PNG or JPEG.
- **Redact Image** flattens adjustable solid, blurred, or pixelated regions into PNG. Review at full resolution with undo and redo. Source metadata is stripped by default, with optional retention of title, author, and copyright.
- **Blur Faces** suggests face masks with Apple Vision. Add or adjust coverage, review the flattened preview, and export PNG with solid cover, blur, or pixelation.
- **Beautify Screenshot** adds a solid or gradient background, padding, rounded corners, and shadow. Choose a canvas aspect ratio, preview the full-resolution composition, and export PNG or JPEG.
- **Rotate Images** previews quarter-turns and horizontal or vertical flips. Export a PNG or keep a supported original format with normalized orientation metadata.
- **Convert Images** exports the primary image to JPEG, PNG, HEIC, or TIFF using Image I/O. A user-selected ImageMagick executable adds WebP. The tool applies orientation and can preserve supported metadata or flatten transparency against a chosen color.
- **Compress Images** uses the same encoding pipeline. **Preview Compression** compares one queued image with a temporary result and shows the measured sizes before export. Compare opens the original and result side by side with linked zoom and position. Pixel zoom uses full detail for images up to 24 megapixels and 8,192 pixels per edge, with reduced previews labeled for larger images. Animated and multi-image sources require an explicit conversion workflow.
- **Remove Metadata** accepts batches of JPEG and PNG and lets you inspect each file before exporting. The native path removes supported location metadata. A user-selected ExifTool executable enables camera, dates, IPTC, and XMP groups. The tool verifies selected fields and checks dimensions, orientation, and color profile before publishing a copy.

Set `MAC_UTILITY_EXIFTOOL_TEST` to a local ExifTool executable to run its integration fixture.


### PDF reader

Open a PDF from **PDF Reader** in the sidebar to browse thumbnails, search, zoom, or print. PDF output and merge previews can open directly in the reader. The **Use in Tool** menu sends the open file to tools such as **Crop PDF**, **Compress PDF**, **PDF to Word**, and **Fill & Flatten Forms**, subject to the document's permissions. In **Settings → PDF Reader**, choose whether macOS should open PDFs with Mac Utility Kit.

Use **Add Password** for an unencrypted PDF or **Remove Password** after opening an encrypted PDF. The protection tool receives the file and prompts separately for the password.

Use **Paste PDF** to open a PDF file copied in Finder or PDF content copied from another app. Pasted PDF content remains available to the reader and its tool handoffs while the workspace is open.

In **Merge PDFs**, use **Paste Image or PDF** to add copied content to the source list. The pasted PDF has the same page-selection controls as a PDF opened from disk.

### PDF page tools

**Split PDF** exports individual pages, fixed-size groups, or named ranges with filename previews. **Organize PDF** supports reordering, rotation, removal, restoration, and in-session undo and redo. **Delete Pages** takes a typed range or thumbnail selections and previews the marked and remaining pages.

Each tool operates on one PDF at a time and writes new copies. These page edits preserve tested page content and rotation. Document-level outlines, tags, and form structure may be omitted. Exported copies of encrypted PDFs are unencrypted.


**Extract Pages** exports selected pages in document or selection order. **Images to PDF** places ordered images on original-size, standard, or custom paper with margins, a background color, and a placement preview. **PDF to Images** renders the selected pages to PNG, JPEG, or HEIC with DPI or pixel limits, visible annotations, and a filename and dimensions preview.


### PDF conversion and protection

- **Compress PDF** estimates savings from a page sample and verifies the exported page geometry, selectable text, and links. Use qpdf for structural compression or Ghostscript for image DPI reduction.
- **Crop PDF** applies precise edge offsets to selected pages and previews the visible area before export.
- **Make PDF Searchable** adds invisible, selectable Vision OCR text to chosen PDF pages. Preview recognized text, choose a language, and optionally skip pages that already contain text.
- **Redact PDF** permanently removes marked content in a rasterized copy of an unencrypted PDF. The copy contains rendered pages, with text selection, links, and forms removed.
- **Web Page to PDF** previews an HTTP or HTTPS page and exports a continuous or paginated PDF. Paginated export supports paper, margins, and print backgrounds.
- **Convert Documents** uses Pandoc and LibreOffice for supported conversion pairs, with text previews and batch filename templates. Plain-text export drops formatting and images.
- **Word to PDF** uses LibreOffice to preview the document at its saved size, A4, US Letter, or US Legal and export selected pages with searchable text and links. Page ranges apply after layout. LibreOffice may substitute missing fonts.
- **PowerPoint to PDF** previews selectable slides, including hidden slides when requested, and exports individual slides or 2-, 4-, or 6-slide handouts. Videos and animations export as static slides.
- **Excel to PDF** previews printed workbook pages and supports sheet and cell ranges, paper and orientation, and fitting to one page wide. Saved print settings are used by default.
- **Markdown to PDF** previews GFM Markdown and exports searchable, paginated PDF with theme, paper, margin, and source-folder image options.
- **Add Password** encrypts a PDF copy with AES-256 and controls printing and copying permissions. **Remove Password** previews the PDF after unlocking it and saves a decrypted copy. Both use a selected qpdf executable.

### Signature and text tools

- **Sign PDF** places a typed or drawn visual signature and optional date label on selected pages of a new PDF copy. It uses PDF annotations for the visual mark. Certificate-based signatures are a different operation.
- **Extract Text** uses embedded PDF text when available and Apple Vision for images, scanned pages, and selected regions. Choose a recognition language or use automatic detection. Turn off embedded text to run OCR across mixed-content pages. Copy or export the result as editable plain text.
- **Capture Text** recognizes text in a selected screen region with Apple Vision. Review, copy, or send the capture to Extract Text. macOS screen capture permission is required.
- **Text to Speech** reads typed text, TXT, RTF, or a PDF text layer with an installed macOS voice. Select a passage and rate, preview and seek, or export WAV.
- **Transcribe** runs whisper.cpp locally using a selected executable and model. Transcribe a time range, edit the timestamped text, export TXT, SRT, or VTT, or send video captions to Burn In Subtitles.
- **Word Counter** uses Apple Natural Language to count words, sentences, and nonblank paragraph tokens. Character counts use Unicode grapheme clusters, and reading time uses your reading speed. The draft stays in memory when switching tools.


### File, Mac, and developer tools

- **QR Code** generates codes for text, web links, and Wi-Fi networks, and reads codes from images. A tiled scan helps recover small codes in wide images up to 24 megapixels and 16,384 pixels per edge.
- **Batch Rename** previews changes from find and replace, case conversion, numbering, and date rules. Date rules can use the original EXIF capture date for photos. Apply the preview in place and undo the last batch from the tool.
- **Find Duplicates** compares exact file contents inside chosen folders and lets you review copies before moving them to the system Trash.
- **Keep Awake** prevents idle sleep for a chosen duration or until stopped, with an option to keep the display awake.
- **JSON Formatter** validates, formats, and minifies JSON, with configurable indentation, key sorting, and duplicate-key warnings.
- **Base64** encodes and decodes text or files as Base64, Base64URL, hex, or binary. Decoded bytes can be exported directly.
- **Hash Generator** calculates MD5, SHA-1, SHA-256, SHA-384, and SHA-512 digests for text and files and compares them with supplied checksums.
- **UUID Generator** generates v4 and v7 identifiers in batches and inspects UUID variants, versions, and v7 timestamps.
- **Timestamp Converter** converts Unix seconds, milliseconds, and microseconds and exposes both possible instants when a local clock repeats.
- **Clean Links** previews the tracking parameters it removes and decodes supported redirects locally. It preserves internationalized addresses, unknown query fields, fragments, and recognized signed links.
- **Lorem Ipsum** generates a specified number of words, sentences, or paragraphs and exports plain text, HTML, or Markdown.
- **Unicode Inspector** shows graphemes, scalar names, invisible characters, and possible lookalikes from Unicode 18.0.0. NFC and NFD can be previewed before applying.
- **Battery Health** reports available charge, power source, cycles, condition, capacity, and connected Bluetooth accessory readings.
- **Diff Checker** compares two UTF-8 texts or files, with inline and side-by-side views, word changes, and navigation.
- **Password Generator** generates random passwords or EFF-wordlist passphrases locally, with configurable rules and a randomness estimate. Generated secrets stay in the current view until copied or cleared.
- **Disk Speed Test** measures sequential reads and writes on a chosen volume in one or three passes, using temporary storage.
- **Zip & Unzip** creates standard or AES-256 ZIPs and extracts selected items from ZIP, RAR, 7z, and TAR. Extraction asks you to read the contents again if the reviewed archive changes. Encrypted format support varies with macOS libarchive.
- **Regex Tester** shows numbered and named ICU regex captures and previews replacements with bounded matching.
- **CSV ↔ JSON** converts CSV to JSON or Markdown and flat JSON rows to CSV. CSV fields remain strings, and malformed records show their location.
- **Coordinate Picker** places or moves two map points, converts decimal and DMS coordinates, measures distance, and looks up a pasted list.
- **Dead Pixel Test** displays five full-screen solid colors on the selected display, with manual or timed cycling.
- **Eject All Disks** groups eligible devices, unmounts individual volumes, and ejects selected devices with per-target outcomes and busy retries.
- **Presentation Mode** can hide desktop items, hide the Dock, and keep the display awake for a timed or manual session. It restores settings it changed when the session ends.
- **Summarize** makes brief or detailed summaries of pasted text, text files, RTF, or selected PDF pages using the available on-device Apple model on macOS 26 or newer.
- **Case Converter** converts whole text or selected lines among prose and identifier cases, with locale-aware capitalization.
- **JWT Decoder** shows token claims and can verify supported HMAC signatures locally with an entered key. Claim checks are shown separately from signature verification.
- **Network Speed Test** uses macOS Network Quality to measure throughput and responsiveness over the active connection.
- **Storage Explorer** scans folder and file sizes, distinguishes apparent and allocated bytes, and rechecks selected items before moving them to Trash.
- **Clipboard History** records supported text and images only after opt-in. It supports session retention, pinning, exclusions, and copy-back.
- **Translate** uses Apple’s on-device language packs for text, Markdown, SRT, and VTT. Markdown exports preserve supported formatting, link targets, and code. Subtitle exports retain cue timing.
- **Ask a Document** retrieves source passages locally and uses Apple Intelligence to answer with verified quotations linked to pages or sections.
- **Reset Permissions** asks macOS to reset one chosen privacy permission for the selected app’s bundle identifier.
- **Scan Document** imports photos or scans, corrects selectable corners, rotates or recolors pages, and saves the ordered pages as a PDF.
- **Fix “App Is Damaged”** inspects signing integrity, quarantine status, and current macOS policy through read-only checks.
- **Login & Background Items** reviews discoverable system entries and opens the native settings for managing them.
- **PDF to Word** uses LibreOffice to export selected pages as flowing editable text or a layout with positioned text and images. Optional OCR handles scans, including pages that already contain some selectable text. Preserve Layout skips OCR for interactive forms.
- **Fill & Flatten Forms** edits PDF form fields, adds text or checkboxes, proposes printed field locations, and saves interactive or flattened copies. Select a Python environment with pypdf for export verification.
- **Hidden Settings** shows and edits a fixed set of Finder, Dock, and macOS preferences, with reset to the macOS default.
- **Clean Keyboard** briefly pauses software keyboard input after a permission check, while keeping the pointer available to stop the session. Release held keys before starting.
- **Wi-Fi Password & QR** creates guest QR codes and can ask macOS to retrieve a password for a selected supported saved network.
- **Organize Downloads** groups images by recorded web origin, copies or moves selected files, or imports them into Photos albums.
- **Uninstall App** previews eligible applications and exact bundle-owned items before moving confirmed choices to Trash.
- **Display Control** uses a user-installed m1ddc executable to read and adjust DDC settings on compatible Apple Silicon external displays.
- **Mouse Fixes** uses a user-installed LinearMouse to apply reversible per-device scroll settings.
- **Launcher settings** offer an optional menu bar item, Dock icon visibility, a configurable global shortcut, and launch at login.


### Terminal and local MCP

The app bundle includes the `muk` executable in `Contents/MacOS`. In a source checkout, run `swift run muk --help`. Use `muk catalog` to list the app’s tool IDs, categories, and declared file input type identifiers as JSON. Each entry’s `automation` field lists its CLI command or its opt-in MCP capability where available. An empty object indicates an app-only tool. The `workspaceStatus` value `registered` indicates that the tool appears in the app’s workspace catalog. The `prerequisites` list records known fixed requirements by surface, including single-PDF input, LibreOffice for the dedicated Office-to-PDF tools, an existing destination for CLI file jobs, and an explicit allow option for MCP. It also identifies qpdf for PDF password exports and yt-dlp for video inspection and download. The list is partial. Tool controls check remaining requirements at runtime, including those specific to a machine, input, or selected option. The CLI reuses the app’s image resize, PDF merge, media inspection, file hashing, and JSON formatting operations. File-producing commands print a JSON report with output paths and per-input failures.

To enable specific MCP operations in a local client, set its command to the app bundle’s absolute `Contents/MacOS/muk` path and give it these arguments:

```json
["mcp", "--allow", "format-json", "--allow", "word-count"]
```

The optional `clean-link` tool is also available. The server uses the client process’s standard input and output and operates on supplied text. It opens no network listener.


### Local installer

Run `./scripts/build-dmg.sh` after building the app to create a verified local preview disk image. The build uses an ad hoc signature by default. For an authorized distribution build, set `MUK_CODESIGN_IDENTITY` to the Developer ID Application identity when running both build scripts. Set `MUK_NOTARY_PROFILE` for the DMG script to submit the final disk image using an authorized Keychain notary profile. The script checks acceptance and staples and validates the ticket before saving the requested disk image. Publication is a separate release step. [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

When building a release, set `MUK_BUNDLE_ID` to the distribution bundle identifier, `MUK_RELEASE_VERSION` to the three-part version users see, and `MUK_BUILD_VERSION` to an incrementing build number. `build-app.sh` applies this metadata before signing. Local builds use the preview identifier and version by default. [Apple bundle version documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring)
