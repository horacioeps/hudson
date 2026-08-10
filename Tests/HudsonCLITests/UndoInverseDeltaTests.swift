import Store
import Testing

@testable import HudsonCLI

/// `undo`'s only real logic: flipping op while keeping the label fixed.
/// Everything else in `UndoCommand` is plumbing (read the newest pending
/// row, enqueue this delta) already covered by `MutationQueue`'s own tests.
@Test func undoInvertsAddToRemove() {
    let delta = UndoCommand.inverseDelta(labelID: "STARRED", op: .add)
    #expect(delta == LabelDelta(labelID: "STARRED", op: .remove))
}

@Test func undoInvertsRemoveToAdd() {
    let delta = UndoCommand.inverseDelta(labelID: "INBOX", op: .remove)
    #expect(delta == LabelDelta(labelID: "INBOX", op: .add))
}
