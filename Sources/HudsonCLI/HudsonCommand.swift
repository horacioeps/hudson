import ArgumentParser

@main
struct HudsonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hudson",
        abstract: "A fast, open-source Gmail client for the Mac.",
        subcommands: [AuthCommand.self, ProfileCommand.self,
                      SyncCommand.self, ListCommand.self, ShowCommand.self,
                      SearchCommand.self, InboxCommand.self,
                      ArchiveCommand.self, UnarchiveCommand.self,
                      StarCommand.self, UnstarCommand.self,
                      ReadCommand.self, UnreadCommand.self,
                      LabelCommand.self, PendingCommand.self, UndoCommand.self]
    )
}
