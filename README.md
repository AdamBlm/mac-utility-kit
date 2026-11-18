# Mac Utility Kit

Working name for an open-source macOS utility suite with its own interface. The foundation build includes Resize Images with multiple sizing modes, Merge PDFs with per-source page selection, and Compress Video with format and quality controls.

- [Feature inventory](docs/feature-inventory.md) — 102 published tools and shared app behavior.
- [Open-source alternatives](docs/open-source-alternatives.md) — what existing projects cover and where a single-app replacement falls short.
- [Open-source reuse map](docs/reuse/README.md) — upstream candidates, licenses, and implementation gaps for each of the 102 tools.
- [Development plan and tool specifications](docs/plan/README.md) — release milestones, controls, outputs, and acceptance checks for all 102 tools.

## Run locally

On an Apple silicon Mac with macOS 15 or later and Xcode installed, run `./scripts/build-app.sh` and open `build/Mac Utility Kit.app`. Run `swift test` to check the workflow fixtures. The generated app is ad hoc signed for local use.


### Video compression engines

The macOS encoder is available on a fresh install and uses bitrate-based quality presets. To use FFmpeg's constant-quality mode, select an installed executable with **Choose FFmpeg…** in Compress Video. The selected FFmpeg build needs libx264 for Automatic or libx265 for HEVC. The app uses codec-specific CRF targets and preserves source resolution and orientation. The sample and full export use the same encoder settings.

The quality and sizing controls are based on [HandBrake's constant-quality model](https://handbrake.fr/docs/en/latest/technical/video-cq-vs-abr.html), [its separate resolution settings](https://handbrake.fr/docs/en/latest/advanced/resizing-video.html), and [FFmpeg's encoder options](https://ffmpeg.org/ffmpeg-codecs.html). FFmpeg is user-supplied. Set `MAC_UTILITY_FFMPEG_TEST` to its executable path when running `swift test` to enable the integration fixture.
