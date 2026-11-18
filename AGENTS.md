# Mac Utility Kit

## Reuse established software first

- Before designing, implementing, or substantially changing a tool, consult the [reuse map](docs/reuse/README.md). Check how mature specialist projects implement the same workflow, using upstream source, documentation, tests, or release history.
- Prefer reusing a suitable established library, executable, or existing project component for the core operation. Integrate it behind the native interface. Judge maturity by adoption, maintenance, release history, and fit.
- When direct reuse is impractical because of licensing, platform support, distribution, or a concrete feature gap, use the upstream implementation as a reference for behavior and defaults. Record the reason for custom code and verify it against representative inputs.
- Check licenses and bundled dependencies before adopting code or redistributing binaries. Document which upstream components the feature uses, which behavior it offers, and which integration checks passed.
