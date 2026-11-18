# Mac Utility Kit

Working name for an open-source macOS utility suite with its own interface. The current build has 35 tools across images, PDFs, media, files, macOS, and development.

- [Feature inventory](docs/feature-inventory.md) — 102 published tools and shared app behavior.
- [Open-source alternatives](docs/open-source-alternatives.md) — what existing projects cover and where a single-app replacement falls short.
- [Open-source reuse map](docs/reuse/README.md) — upstream candidates, licenses, and implementation gaps for each of the 102 tools.
- [Development plan and tool specifications](docs/plan/README.md) — release milestones, controls, outputs, and acceptance checks for all 102 tools.

## Run locally

On an Apple silicon Mac with macOS 15 or later and Xcode installed, run `./scripts/build-app.sh` and open `build/Mac Utility Kit.app`. Run `swift test` to check the workflow fixtures. The generated app is ad hoc signed for local use.


### Video compression engines

The macOS encoder is available on a fresh install and uses bitrate-based quality presets. To use FFmpeg's constant-quality mode, select an installed executable with **Choose FFmpeg…** in Compress Video. The selected FFmpeg build needs libx264 for Automatic or libx265 for HEVC. The app uses codec-specific CRF targets and preserves source resolution and orientation. The sample and full export use the same encoder settings.

The quality and sizing controls are based on [HandBrake's constant-quality model](https://handbrake.fr/docs/en/latest/technical/video-cq-vs-abr.html), [its separate resolution settings](https://handbrake.fr/docs/en/latest/advanced/resizing-video.html), and [FFmpeg's encoder options](https://ffmpeg.org/ffmpeg-codecs.html). FFmpeg is user-supplied. Set `MAC_UTILITY_FFMPEG_TEST` to its executable path when running `swift test` to enable the integration fixture.

Resize Images also supports a user-installed ImageMagick 7 executable via **Choose ImageMagick…**. See the [implementation audit](docs/reuse/implementation-audit.md) for supported engine paths and how to run the upstream integration tests.


### Media tools

- **Convert Video** converts to MP4, MOV, and M4V with AVFoundation. A user-selected FFmpeg adds WebM export and resolution and frame rate options. Passthrough requires streams compatible with the destination container.
- **Media Info** inspects streams locally and exports a JSON report. The native engine exports labeled sections, while the optional user-selected ffprobe exports its detailed stream metadata. Frame-timing results describe observed samples only.
- **Extract Audio** previews one selected track and exports it to M4A, WAV, or AIFF. A user-selected FFmpeg adds MP3 and FLAC. Source track discovery uses AVFoundation. Passthrough is supported for AAC and ALAC tracks in M4A.

Set `MAC_UTILITY_FFPROBE_TEST` to a local ffprobe binary to exercise the external Media Info integration fixture.


- **Change Speed** adjusts video timing with optional pitch preservation. Pitch-preserving export uses AVFoundation. Changing pitch along with speed requires a selected FFmpeg executable for clips with audio.
- **Extract Frames** scrubs and previews source video, then exports selected timestamps or a fixed interval to PNG, JPEG, or HEIC. It uses the video formats supported by AVFoundation.

- **Trim Video** previews an in/out range, re-encodes a precise MP4 cut, or copies video and audio streams to MKV at keyframe-aligned boundaries with selected FFmpeg and ffprobe executables.
- **Mute Video** previews the audio track list and removes selected tracks or all audio. It copies encoded video through AVFoundation when the chosen MOV, MP4, or M4V container supports the retained streams.

- **Resize Video** previews fit, fill, or stretch framing and exports aligned MP4 dimensions. Choose a preset from 480p through 2160p, a percentage, or exact dimensions with optional aspect lock.
- **Video to GIF** previews a clip sample and estimates its size, then uses a selected FFmpeg executable to export an animated GIF with width, frame rate, palette, dithering, and loop controls.

- **Crop & Rotate Video** uses draggable crop handles, aspect presets, exact coordinates, quarter-turn rotations, and mirroring. Preview the edited frame before exporting MP4.

- **Merge Videos** reorders clips, previews the cut between clips, and exports one MP4 or MOV. Normalize fits mixed clips to a common frame. Compatible clips can use passthrough, with control over whether to retain primary audio.

- **Replace Audio** replaces or mixes a selected soundtrack with the original. Set track gains, an offset, and a duration policy, and listen to a short preview before exporting MP4.
- **Burn In Subtitles** imports or edits SRT cues, shifts their timing, and previews subtitle styling on a selected video frame. MP4 export uses a selected FFmpeg build with libass.

- **Trim Audio** selects a sample-accurate range with a waveform, time fields, and a looping preview. Export WAV, AIFF, or M4A with optional fades, or preserve PCM samples in matching WAV or AIFF output.

### Image tools

- **Convert Images** exports the primary image to JPEG, PNG, HEIC, or TIFF using Image I/O. A user-selected ImageMagick executable adds WebP. The tool applies orientation and can preserve supported metadata or flatten transparency against a chosen color.
- **Compress Images** uses the same encoding pipeline. It reports measured sizes and whether a best-effort size goal was reached. Compare opens the original and result side by side with linked zoom. Animated and multi-image sources require an explicit conversion workflow.
- **Remove Metadata** works on single-image JPEG and PNG. The native path removes supported location metadata. A user-selected ExifTool executable enables camera, dates, IPTC, and XMP groups. The tool verifies selected fields and checks dimensions, orientation, and color profile before publishing a copy.

Set `MAC_UTILITY_EXIFTOOL_TEST` to a local ExifTool executable to run its integration fixture.


### PDF reader

Open a PDF from **PDF Reader** in the sidebar to browse thumbnails, search, zoom, print, or send the source to a document tool. PDF output and merge previews can open directly in the reader.

### PDF page tools

**Split PDF** exports individual pages, fixed-size groups, or named ranges with filename previews. **Organize PDF** supports reordering, rotation, removal, restoration, and in-session undo and redo. **Delete Pages** takes a typed range or thumbnail selections and previews the marked and remaining pages.

Each tool operates on one PDF at a time and writes new copies. These page edits preserve tested page content and rotation. Document-level outlines, tags, and form structure may be omitted. Exported copies of encrypted PDFs are unencrypted.


**Extract Pages** exports selected pages in document or selection order. **Images to PDF** places ordered images on original-size, standard, or custom paper with margins, a background color, and a placement preview. **PDF to Images** renders the selected pages to PNG, JPEG, or HEIC with DPI or pixel limits, visible annotations, and a filename and dimensions preview.


### Signature and text tools

- **Sign PDF** places a typed or drawn visual signature and optional date label on selected pages of a new PDF copy. It uses PDF annotations for the visual mark. Certificate-based signatures are a different operation.
- **Extract Text** uses embedded PDF text when available and Apple Vision for images, scanned pages, and selected regions. Choose a recognition language or use automatic detection. Turn off embedded text to run OCR across mixed-content pages. Copy or export the result as editable plain text.
- **Word Counter** uses Apple Natural Language to count words, sentences, and nonblank paragraph tokens. Character counts use Unicode grapheme clusters, and reading time uses your reading speed. The draft stays in memory when switching tools.


### File, Mac, and developer tools

- **QR Code** generates codes for text, web links, and Wi-Fi networks, and reads codes from images.
- **Batch Rename** previews changes from find and replace, case conversion, numbering, and date rules. Apply the preview in place and undo the last batch from the tool.
- **Keep Awake** prevents idle sleep for a chosen duration or until stopped, with an option to keep the display awake.
- **JSON Formatter** validates, formats, and minifies JSON, with configurable indentation, key sorting, and duplicate-key warnings.
- **Base64** encodes and decodes text or files as Base64, Base64URL, hex, or binary. Decoded bytes can be exported directly.
- **Hash Generator** calculates MD5, SHA-1, SHA-256, SHA-384, and SHA-512 digests for text and files and compares them with supplied checksums.
