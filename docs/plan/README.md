# Mac Utility Kit development plan

Build an original, local-first SwiftUI app for Apple silicon on macOS 15 and later. The app currently has three foundation tools. This plan defines the scope for completing them and releasing the rest of the suite.

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
| v0.3 · 71 tools | Finish documents and text/speech. Choose the production inference provider before shipping Summarize and Ask a Document. |
| v0.4 · 85 tools | Finish files and developer tools. Add CLI and opt-in local MCP for approved, non-interactive operations. |
| v1.0 · 102 tools | Finish Mac utilities, menu bar mode, global shortcut, launch at login, and optional draft retention. Prototype OS-sensitive behaviors early. |

## Release requirements

A tool ships when its planned controls work from the normal app entry point, its result passes the row's checks, and unsupported modes have a clear explanation. Cover clean macOS 15 and current macOS installs, keyboard workflows, large or malformed inputs, mixed-success batches, cancellation, name conflicts, and denied permissions.

Use Apache-2.0 as the provisional license for original code. Confirm it before source publication and review the pinned licenses of bundled dependencies, executables, and models. Release signed and notarized DMGs through GitHub after signing credentials and publication are approved. The AI provider remains open and does not affect v0.1.
