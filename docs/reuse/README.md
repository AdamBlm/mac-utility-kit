# Open-source reuse map

Each advertised tool in the [Feature inventory](../feature-inventory.md) has a row with established upstream candidates or a native implementation path. The rows record licenses and the remaining work.

| Area | Features |
| --- | ---: |
| [Video, audio, and images](media.md) | 33 |
| [Documents, text, and speech](documents-and-speech.md) | 32 |
| [Files and Mac utilities](files-and-mac.md) | 23 |
| [Developer tools](developer.md) | 14 |
| **Total** | **102** |

A repository can supply a ready-made operation, an implementation to study, or a building block. Some rows require original macOS integration, and some candidates overlap with only part of the feature. The license labels describe the upstream projects. Before adopting a dependency, check the license of the specific revision, optional dependencies, bundled data or models, and the planned distribution method. The project has yet to select an app license.

The map is based on upstream source and documentation. Candidates have yet to be built or tested together.

## Upstream maturity

The [candidate audit](upstream-audit.md) records adoption, forks, last push, and release or tag evidence. This pass uses roughly 500 GitHub stars as an adoption signal, alongside ownership, release history, and fit. Smaller repositories qualify when they ship as part of an established project or have a clear specialist role and maintenance evidence. A recent push alone can be a mirror sync, and a popular repo can still be dormant or unsuitable for embedding.

Where sources cover only part of a feature, the map specifies what we would build. Four tools currently use native implementation paths without a recommended upstream project: Organize Downloads, Network Speed Test, Clean Keyboard, and Reset Permissions.

## Shared app behavior

- **Tool launcher and login** — [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) (MIT) supplies configurable global shortcuts. [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) (MIT) wraps the system login registration. Search, tool routing, and menu bar behavior belong in the app.
- **Local workspace and job history** — [GRDB.swift](https://github.com/groue/GRDB.swift) (MIT) supplies a Swift persistence layer. The app needs to implement state retention, job execution and cancellation, progress, and output folder rules.
- **PDF reader** — [Skim](https://skim-app.sourceforge.io/) provides a native reader reference with thumbnails, search, printing, and document handling. Its [source repository](https://sourceforge.net/p/skim-app/code/HEAD/tree/) uses a BSD license. Tool handoffs and default-app registration are separate integration work.
- **CLI and MCP** — [Swift Argument Parser](https://github.com/apple/swift-argument-parser) (Apache-2.0) handles the CLI interface. The [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) supplies server plumbing. Its license file describes an MIT-to-Apache-2.0 transition. Tool registration, client setup, and permission controls belong in the app.
- **Updates** — [Sparkle](https://github.com/sparkle-project/Sparkle) supplies macOS update delivery (MIT-style license with third-party notices in its license file). Signing and notarization use Apple's distribution tooling.
