import ArgumentParser

@main
struct MacUtilityCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "muk",
        abstract: "Run local Mac Utility Kit tools from the terminal.",
        subcommands: [ResizeImages.self, MergePDFs.self, MediaInfo.self, Hash.self, FormatJSON.self, StartMCP.self]
    )
}
