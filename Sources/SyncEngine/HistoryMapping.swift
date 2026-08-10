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
            for added in record.messagesAdded ?? [] {
                if let snapshot = SnapshotMapping.snapshot(from: added.message) {
                    changes.append(HistoryChange(kind: .added(snapshot)))
                }
            }
            for change in (record.labelsAdded ?? []) + (record.labelsRemoved ?? []) {
                changes.append(HistoryChange(kind: .labels(
                    id: change.message.id,
                    historyID: version,
                    labelIDs: change.message.labelIds ?? [])))
            }
            for deleted in record.messagesDeleted ?? [] {
                changes.append(HistoryChange(kind: .deleted(id: deleted.message.id)))
            }
        }
        return changes
    }
}
