# Mac Utility Kit

## Reuse established software first

- Before designing, implementing, or substantially changing a tool, consult the [reuse map](docs/reuse/README.md). Check how mature specialist projects implement the same workflow, using upstream source, documentation, tests, or release history.
- Prefer reusing a suitable established library, executable, or existing project component for the core operation. Integrate it behind the native interface. Judge maturity by adoption, maintenance, release history, and fit.
- When direct reuse is impractical because of licensing, platform support, distribution, or a concrete feature gap, use the upstream implementation as a reference for behavior and defaults. Record the reason for custom code and verify it against representative inputs.
- Check licenses and bundled dependencies before adopting code or redistributing binaries. Document which upstream components the feature uses, which behavior it offers, and which integration checks passed.

## Keep the UI and processing engines replaceable

- Use the current native workspace as the approved design baseline. Keep its compact window chrome, focused empty state, and progressive disclosure consistent across tools. Put shared visual tokens and components in the presentation layer. Keep window layout, per-tool controls, and session coordination separate so a visual overhaul can replace them independently.
- Keep processing in `UtilityCore`, with focused operations and engine adapters for each domain. Engine code accepts explicit inputs and options and reports progress, cancellation, results, and errors independently of SwiftUI. Shared job orchestration owns staging, batching, and publication. Add domain behavior in the relevant operation or adapter.
- Keep interfaces small and prefer established framework boundaries. Introduce a shared abstraction when multiple callers genuinely need the same behavior. Verify changes through existing workflow tests and run the relevant engine integration fixture when changing an adapter.
