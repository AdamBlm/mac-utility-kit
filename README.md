# Mac Utility Kit

Working name for an open-source macOS utility suite with its own interface. The foundation build includes Resize Images with multiple sizing modes, Merge PDFs with per-source page selection, and Compress Video with format and quality controls.

- [Feature inventory](docs/feature-inventory.md) — 102 published tools and shared app behavior.
- [Open-source alternatives](docs/open-source-alternatives.md) — what existing projects cover and where a single-app replacement falls short.
- [Open-source reuse map](docs/reuse/README.md) — upstream candidates, licenses, and implementation gaps for each of the 102 tools.
- [Development plan and tool specifications](docs/plan/README.md) — release milestones, controls, outputs, and acceptance checks for all 102 tools.

## Run locally

On an Apple silicon Mac with macOS 15 or later and Xcode installed, run `./scripts/build-app.sh` and open `build/Mac Utility Kit.app`. Run `swift test` to check the workflow fixtures. The generated app is ad hoc signed for local use.
