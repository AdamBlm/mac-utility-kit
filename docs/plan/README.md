# Mac Utility Kit development plan

Build an original, local-first SwiftUI app for Apple silicon on macOS 15 and later. This plan defines the foundation work, tool scope, and release requirements.

## Tool specifications

| Area | Planned tools |
| --- | ---: |
| [Video, audio, and images](media.md) | 33 |
| [Documents, text, and speech](documents-and-speech.md) | 32 |
| [Files and macOS utilities](files-and-mac.md) | 23 |
| [Developer tools](developer.md) | 14 |
| **Total** | **102** |

Each row specifies user controls, results, and acceptance checks. Use the [feature inventory](../feature-inventory.md) as the scope baseline and the [reuse map](../reuse/README.md) to evaluate upstream components.

## Foundation completion checklist

- **Merge PDFs** — Select pages independently for each source using thumbnails or typed page ranges. Show the resulting page order before export. Treat each imported image as one page. Report invalid ranges, locked PDFs, and empty output before starting the merge.
- **Compress Video** — Choose an output format and compression quality before running. Show availability by input and engine. Report original size, output size, and savings for each file.
- **Resize Images** — Choose percentage, longest edge, or exact dimensions. Preview the resulting size and choose output format and quality where applicable. Make aspect ratio and upscaling behavior explicit.

## Shared design

- Use a compact category sidebar, searchable tool list, and focused workspace. Keep file order, options, previews, and results together. Provide keyboard navigation, accessible control labels and focus, and system light/dark appearance.
- Use a consistent file flow with drag-and-drop, a file picker, visible per-file validation, output location, progress and cancellation, and Open or Reveal actions. Widen the workspace for tools that need page thumbnails, timelines, or side-by-side comparison. Keep in-progress drafts per tool.
- Show supported formats and options before starting. Gate formats by installed engine capabilities. Keep common formats available with system frameworks and detect optional user-installed FFmpeg for additional modes.
- Snapshot inputs and options on Run. Preserve originals for export tools, stage outputs, and use unique result folders. Report failures per input for independent batches. For combined outputs, such as a merged PDF, validate all selected inputs before committing the result.
- Preview and confirm file mutations or system changes, with recovery where feasible. Request macOS permissions only when used. Keep processing local by default and identify actions that contact a service. Keep sensitive values out of logs and retained drafts.
- Keep processing separate from the SwiftUI workspace. Add new tools to a shared catalog with stable IDs, supported inputs, prerequisites, and status. Reuse the same validated operations in the app, CLI, and local MCP where appropriate.

## Release sequence

| Release | Deliverable |
| --- | --- |
| Foundation | Extend Resize Images, Merge PDFs, and Compress Video to the linked specifications. Validate the shared file flow, previews, and background jobs with these tools. |
| v0.1 · 24 tools | Compress Video, Convert Video, Media Info, Extract Audio, Convert Images, Compress Images, Resize Images, Remove Metadata, Merge PDFs, Split PDF, Organize PDF, Delete Pages, Extract Pages, Images to PDF, PDF to Images, Sign PDF, Extract Text, Word Counter, QR Code, Batch Rename, Keep Awake, JSON Formatter, Base64, and Hash Generator. Add the PDF reader with search, thumbnails, printing, and tool handoffs. |
| v0.2 · 52 tools | Finish video, audio, and images. Add Transcribe, Capture Text, and Text to Speech. |
| v0.3 · 71 tools | Finish documents and text/speech. Verify Summarize and Ask a Document against the on-device Apple Intelligence model. |
| v0.4 · 85 tools | Finish files and developer tools. Add CLI and opt-in local MCP for approved, non-interactive operations. |
| v1.0 · 102 tools | Finish Mac utilities, menu bar mode, global shortcut, launch at login, and optional draft retention. Prototype OS-sensitive behaviors early. |

## Release requirements

A tool ships when its planned controls work from the normal app entry point, its result passes the row's checks, and unsupported modes have a clear explanation. Cover clean macOS 15 and current macOS installs, keyboard workflows, large or malformed inputs, mixed-success batches, cancellation, name conflicts, and denied permissions.

Use Apache-2.0 as the provisional license for original code. Confirm it before source publication and review the pinned licenses of bundled dependencies, executables, and models. Release signed and notarized DMGs through GitHub after signing credentials and publication are approved. Summarize and Ask a Document use Apple Intelligence through Foundation Models. Generated output requires an eligible Mac with macOS 26 or later and a ready system model. The app bundles no inference model and uses no remote fallback.

## Public release and managed engines

See the [release procedure](engine-release.md) for artifact review, signing, and rollout.

1. **Prove the Download Video setup on a clean Mac.** Open the app from the signed, notarized DMG and choose **Install Video Tools** in the tool. Show the download size and progress, support cancellation and retry, and resume the pending action once setup succeeds. Install the official standalone macOS yt-dlp with its bundled EJS scripts, an upstream-supported Deno build, and a matched FFmpeg/FFprobe pair in per-user Application Support. Pass explicit Deno and FFmpeg paths to yt-dlp during both inspection and download, using bundled EJS scripts. Keep the existing user-selected executable option.
2. **Qualify a redistributable FFmpeg build.** Use a pinned GPL-enabled FFmpeg/FFprobe pair as the starting point because existing tools use libx264 and libx265. Retain the existing CLI process boundary and confirm the license obligations for the exact packaging before release. Start from an established upstream build recipe and verify VideoToolbox, libass subtitles, merging, probing, and existing software-encoding options. Reject `--enable-nonfree`. Publish the license notices, matching source for FFmpeg and included libraries, patches, and build instructions alongside every hosted binary version. Link these from Settings and the download page. Audit the actual yt-dlp and Deno artifacts and their bundled dependencies as well. [FFmpeg licensing](https://ffmpeg.org/doxygen/trunk/md_LICENSE.html) · [yt-dlp EJS setup](https://github.com/yt-dlp/yt-dlp/wiki/EJS)
3. **Keep setup separate from processing.** Add a shared engine manager with a versioned manifest and small per-engine adapters that declare capabilities and validate installations. Reuse the existing process runner. Tools resolve explicit executable paths through the shared layer, and Settings presents installed versions and install, update, repair, and remove actions. Keep GUI state in the app target. Native tools remain available immediately. Add other external engines and models in later passes after checking upstream packaging and licenses.
4. **Ship engine updates independently.** CI detects upstream releases, verifies upstream signatures where available, and runs compatibility checks before publishing an updated signed manifest. The app checks signatures against a built-in public key, rejects older manifest revisions, verifies artifact hashes and platform compatibility, and downloads only expected executables within declared size limits before activating the tested engine set atomically. Hold the previous verified version for rollback and keep running jobs on the versions they started with. Installed engines continue to work offline where the operation supports it. Sparkle handles signed app updates through a separate release feed. [Sparkle documentation](https://sparkle-project.org/documentation/)
5. **Gate the public release on actual first-run behavior.** Test the signed and notarized DMG on clean macOS 15 and current macOS, on each supported architecture. Verify Gatekeeper behavior, first-use install, a real video inspection and merge, a media regression suite, interrupted installs, invalid signatures or hashes, upgrade and rollback, and preservation of user-selected tools. Move from private preview to opt-in public beta, then stable. Publish the DMG, licenses, and source links after those checks and release authorization.

## Code boundaries

The approved workspace uses a compact native title bar, a focused file-first empty state, and an Advanced disclosure. The app target owns window composition, tool presentation, and per-window state. `WorkspaceStyle` holds shared visual components, `ToolSettings` holds individual controls, and `WorkspaceSession` coordinates drafts and jobs.

`UtilityCore` supplies the tool catalog and callable operations. `ToolRunner` owns file staging, batching, publishing results, and dispatching to the relevant domain. Each domain owns its processing rules and selects an engine adapter where needed. ImageMagick, FFmpeg, and AVFoundation adapters can evolve independently of the interface. Workflow tests exercise the same entry points as the app.
