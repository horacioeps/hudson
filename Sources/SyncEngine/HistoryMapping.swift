import GmailKit
import Store

/// Flattens Gmail history records into the Store's ordered change list.
enum HistoryMapping {
    /// Order within and across records is preserved — the Store applies
    /// changes exactly in this sequence (spec §4.3).
    static func changes(from records: [HistoryRecord]) -> [HistoryChange] {
        var changes: [HistoryChange] = []
        for record in records {
            let version = Int64(record.id) ?? 0
            // Every history message reference is MINIMAL (id + the message's
            // current labels — Gmail sends no content or per-message historyId
            // here, see `HistoryMessageStub`). So a NEW message (`messagesAdded`)
            // is emitted as a `.labels` change too: `applyHistoryChanges`
            // reports it as an "unknown id", which `SyncEngine.pollHistory`
            // then fetches in full via `getMessage`. That reconciliation is
            // exactly why we don't (and can't) build a snapshot from the stub.
            for change in (record.messagesAdded ?? [])
                + (record.labelsAdded ?? []) + (record.labelsRemoved ?? [])
            {
                changes.append(HistoryChange(kind: .labels(
                    id: change.id, historyID: version, labelIDs: change.labelIds ?? [])))
            }
            for deleted in record.messagesDeleted ?? [] {
                changes.append(HistoryChange(kind: .deleted(id: deleted.id)))
            }
        }
        return changes
    }
}
