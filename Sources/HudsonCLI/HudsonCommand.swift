import ArgumentParser

@main
struct HudsonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hudson",
        abstract: "A fast, open-source Gmail client for the Mac.",
        subcommands: []
    )
}
