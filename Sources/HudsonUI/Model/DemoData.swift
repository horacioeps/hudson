import Foundation
import Store

/// A synthetic, 100%-fictional demo mailbox: ~40 inbox threads spread
/// across the `primary`/`important`/`team` splits and Gmail's
/// `updates`/`promotions`/`social` categories, seeded through the SAME
/// write path `SyncEngine` uses (`setSplitRules` → `applySnapshots` →
/// `saveBody`) — never by hand-writing `thread_rollup` rows. Used by
/// `--demo`/`AppModel.demo()` for screenshots and by tests/previews that
/// want a realistic-looking store without touching a real mailbox.
///
/// Every name, address, subject, and body below is invented. Every domain
/// is a fictional `.example` domain (RFC 2606) — never a real company.
public enum DemoData {

    /// Inserts the demo account, its split rules and sidebar labels, then
    /// ~40 synthetic threads with their bodies/attachments. Order matters:
    /// `setSplitRules` runs BEFORE `applySnapshots`, which loads the
    /// account's rules once at the start of the batch and threads them
    /// into rollup maintenance (`HudsonDatabase.applySnapshots`) — rules
    /// set afterward would never affect `split_key`.
    ///
    /// Timestamps derive from `Date.now` minus a fixed per-thread/per-message
    /// offset — never random — so the SHAPE of the seed (thread/message
    /// counts, which threads are unread/starred/attached, which split each
    /// lands in) is stable across runs even as the wall-clock values drift.
    public static func seed(into database: HudsonDatabase, account: String = "you@hudson.app") async throws {
        let now = Date.now
        try await database.upsertAccount(email: account, clientID: "demo-client", consentedAt: now)
        try await database.setSplitRules(splitRules, account: account)
        try await database.upsertLabels(sidebarLabels, account: account)

        var snapshots: [MessageSnapshot] = []
        var bodySaves: [BodySave] = []
        for (threadIndex, thread) in threads.enumerated() {
            let expanded = thread.expand(threadIndex: threadIndex, now: now, account: account)
            snapshots.append(contentsOf: expanded.snapshots)
            bodySaves.append(contentsOf: expanded.bodySaves)
        }

        _ = try await database.applySnapshots(snapshots, account: account)
        for save in bodySaves {
            try await database.saveBody(
                messageID: save.messageID, account: account, body: save.body,
                attachments: save.attachments)
        }
    }

    // MARK: - Split rules + sidebar labels

    /// Routes Priya's mail to "important" and anyone @northwind.example to
    /// "team" — the two rules the `threads` below are built to hit.
    private static let splitRules: [SplitRule] = [
        SplitRule(ordinal: 0, kind: .sender, value: "priya@meridian.example", splitName: "important"),
        SplitRule(ordinal: 1, kind: .domain, value: "northwind.example", splitName: "team"),
    ]

    private static let sidebarLabels: [(id: String, name: String)] = [
        (id: "Label_1", name: "Receipts"),
        (id: "Label_2", name: "Travel"),
        (id: "Label_3", name: "Newsletters"),
    ]

    // MARK: - Cast (fictional; every address below is invented)

    private static let priya = "Priya Anand <priya@meridian.example>"  // -> "important"
    private static let maya = "Maya Chen <maya@northwind.example>"  // -> "team"
    private static let jonah = "Jonah Ruiz <jonah@northwind.example>"  // -> "team"
    private static let northwindFinance = "Northwind Finance <billing@northwind.example>"  // -> "team"

    private static let sofia = "Sofia Petrov <sofia@brightleaf.example>"
    private static let derek = "Derek Osei <derek@brightleaf.example>"
    private static let ana = "Ana Souza <ana@fernbridge.example>"
    private static let milo = "Milo Tran <milo@fernbridge.example>"
    private static let arborCoworking = "Arbor Coworking <hello@arbor.example>"
    private static let whistlecreekHOA = "Whistlecreek HOA <board@whistlecreek.example>"
    private static let kiteAndKey = "Petra Lindqvist <petra@kiteandkey.example>"
    private static let pixelHarborSupport = "Pixel Harbor Support <support@pixelharbor.example>"
    private static let trailheadTravel = "Trailhead Travel <bookings@trailhead.example>"
    private static let cinderpeakBank = "Cinderpeak Bank <alerts@cinderpeak.example>"

    private static let codepine = "Codepine <notifications@codepine.example>"
    private static let novaFitness = "Nova Fitness <updates@novafitness.example>"
    private static let dailyLoom = "The Daily Loom <news@dailyloom.example>"

    private static let fernwoodMarket = "Fernwood Market <deals@fernwood.example>"
    private static let glasswingStudio = "Glasswing Studio <sale@glasswing.example>"
    private static let harborRoast = "Harbor Roast Coffee <offers@harborroast.example>"
    private static let driftwoodOutfitters = "Driftwood Outfitters <deals@driftwoodoutfitters.example>"
    private static let lumenHome = "Lumen Home Goods <promo@lumenhome.example>"

    private static let buzzline = "Buzzline <notify@buzzline.example>"
    private static let frontPorch = "Front Porch <hello@frontporch.example>"
    private static let handshakeNetwork = "Handshake Network <digest@handshake.example>"
    private static let ridgelineRunClub = "Ridgeline Run Club <no-reply@ridgelinerun.example>"
    private static let orbitPhotos = "Orbit Photos <memories@orbitphotos.example>"

    // MARK: - Threads

    /// ~40 synthetic threads. `ThreadSeed.expand` turns each into 1-3
    /// `MessageSnapshot`s (oldest -> newest) plus any `saveBody` calls.
    /// Grouped by intended split/category below for readability; the
    /// account's `splitRules` (sender→"important", domain→"team") plus
    /// Gmail's own `CATEGORY_*` fallback are what actually place each
    /// thread — nothing here hardcodes a `splitKey`.
    private static let threads: [ThreadSeed] = [
        // MARK: Primary (no rule/category match) — 16 threads, incl. 2 multi-message

        ThreadSeed(
            id: "t01", hoursAgo: 2,
            messages: [
                .init(from: sofia, subject: "Dinner Friday?",
                      snippet: "Are we still on for dinner Friday? Thinking that new noodle place."),
                .init(from: sofia, subject: "Dinner Friday?",
                      snippet: "Sounds great, see you at 7!", extraLabels: ["SENT"],
                      to: "sofia@brightleaf.example"),
                .init(from: sofia, subject: "Re: Dinner Friday?",
                      snippet: "Perfect — I'll grab us a table by the window. See you then!",
                      body: "Perfect — I'll grab us a table by the window. See you then!",
                      extraLabels: ["UNREAD", "STARRED"]),
            ]),
        .single(id: "t02", hoursAgo: 5, from: whistlecreekHOA,
                subject: "Reminder: gutter cleaning this Saturday",
                snippet: "This is a reminder that the annual gutter cleaning is scheduled for Saturday morning.",
                unread: true),
        .single(id: "t03", hoursAgo: 9, from: ana, subject: "Quick question about the lease renewal",
                snippet: "Wanted to check whether the renewal needs to go through the portal or by email.",
                body: "Hi — wanted to check whether the lease renewal needs to go through the portal or "
                    + "just by email this time. Let me know when you get a chance, no rush."),
        .single(id: "t04", hoursAgo: 13, from: milo, subject: "Photos from the weekend",
                snippet: "Finally got around to sorting through these — a few are actually decent!",
                body: "Finally got around to sorting through the weekend photos — a few are actually "
                    + "decent! Zipped up the full set for you, figured you'd want the originals.",
                attachment: AttachmentMeta(
                    id: "t04-att1", filename: "weekend-photos.zip", mimeType: "application/zip",
                    size: 8_400_000),
                unread: true, starred: true),
        .single(id: "t05", hoursAgo: 17, from: arborCoworking, subject: "Your desk reservation is confirmed",
                snippet: "You're all set for Tuesday and Thursday this week at the Fifth Street location.",
                body: "You're all set for Tuesday and Thursday this week at the Fifth Street location. "
                    + "Badge access opens at 7am; let us know if your schedule changes."),
        .single(id: "t06", hoursAgo: 22, from: kiteAndKey, subject: "Open house this Saturday at 2pm",
                snippet: "The Birchwood listing is holding an open house this Saturday from 2 to 4pm.",
                unread: true),
        .single(id: "t07", hoursAgo: 27, from: pixelHarborSupport,
                subject: "Re: Ticket #48213 — sync issue resolved",
                snippet: "Good news — we tracked down the sync issue and shipped a fix earlier today.",
                body: "Good news — we tracked down the sync issue and shipped a fix earlier today. "
                    + "You shouldn't need to do anything on your end; let us know if it recurs."),
        .single(id: "t08", hoursAgo: 33, from: trailheadTravel,
                subject: "Your itinerary: Denver, Aug 14-17",
                snippet: "Your flights and hotel confirmation for the Denver trip are attached.",
                body: "Your flights and hotel confirmation for the Denver trip are attached. Checked "
                    + "bags are included on both legs; boarding passes open 24 hours before departure.",
                attachment: AttachmentMeta(
                    id: "t08-att1", filename: "denver-itinerary.pdf", mimeType: "application/pdf",
                    size: 210_000)),
        ThreadSeed(
            id: "t09", hoursAgo: 39,
            messages: [
                .init(from: derek, subject: "Contract redlines",
                      snippet: "Sending over a first pass at the redlines — mostly minor wording."),
                .init(from: derek, subject: "Re: Contract redlines",
                      snippet: "Second pass attached — this should be the final version.",
                      body: "Second pass attached — this should be the final version. Let me know if "
                          + "section 4 still needs another look before we send it out.",
                      attachment: AttachmentMeta(
                          id: "t09-att1", filename: "contract-v2.pdf", mimeType: "application/pdf",
                          size: 540_000)),
            ]),
        .single(id: "t10", hoursAgo: 46, from: cinderpeakBank, subject: "Your July statement is ready",
                snippet: "Your July account statement is now available to view online.",
                body: "Your July account statement is now available to view online. Your paperless "
                    + "settings mean you won't receive a mailed copy — let us know if you'd like one."),
        .single(id: "t11", hoursAgo: 53, from: ana, subject: "Coffee next week?",
                snippet: "Free Tuesday or Wednesday morning if you want to catch up?", unread: true),
        .single(id: "t12", hoursAgo: 61, from: whistlecreekHOA, subject: "Board meeting minutes — July",
                snippet: "Minutes from last week's board meeting are attached for anyone who missed it.",
                body: "Minutes from last week's board meeting are attached for anyone who missed it. "
                    + "Next meeting is the second Tuesday of next month, same time."),
        .single(id: "t13", hoursAgo: 70, from: kiteAndKey, subject: "Inspection report attached",
                snippet: "The inspector's full report on 142 Birchwood is attached — a few items to flag.",
                body: "The inspector's full report on 142 Birchwood is attached — a few items worth "
                    + "flagging before we move forward, mostly around the roof and the water heater.",
                attachment: AttachmentMeta(
                    id: "t13-att1", filename: "142-birchwood-inspection.pdf", mimeType: "application/pdf",
                    size: 1_250_000),
                unread: true),
        .single(id: "t14", hoursAgo: 80, from: sofia, subject: "Book club pick for next month",
                snippet: "Putting it to a vote — three options below, reply with your favorite.",
                unread: true),
        .single(id: "t15", hoursAgo: 91, from: arborCoworking, subject: "Community mixer this Thursday",
                snippet: "Drop by the lounge Thursday evening for drinks and to meet other members."),
        .single(id: "t16", hoursAgo: 103, from: milo, subject: "Can you review my slides before tomorrow?",
                snippet: "Nothing major, just want a second pair of eyes before the 9am review.",
                body: "Nothing major, just want a second pair of eyes before the 9am review tomorrow. "
                    + "Nine slides, should be a five-minute read.",
                unread: true),

        // MARK: Important (sender rule: priya@meridian.example) — 4 threads

        ThreadSeed(
            id: "t17", hoursAgo: 4,
            messages: [
                .init(from: priya, subject: "Proposal draft — final review",
                      snippet: "Here's the draft — let me know what you think before it goes out."),
                .init(from: priya, subject: "Re: Proposal draft — final review",
                      snippet: "Looks great overall, a few notes inline.", extraLabels: ["SENT"],
                      to: "priya@meridian.example"),
                .init(from: priya, subject: "Re: Proposal draft — final review",
                      snippet: "Updated based on your notes — ready to send on my end.",
                      body: "Updated based on your notes — ready to send on my end whenever you are. "
                          + "Flagging that the timeline slide still needs your sign-off.",
                      extraLabels: ["UNREAD", "STARRED"]),
            ]),
        .single(id: "t18", hoursAgo: 20, from: priya, subject: "Meeting notes: kickoff call",
                snippet: "Notes from this morning's kickoff — action items at the bottom.",
                body: "Notes from this morning's kickoff call are below — action items are at the "
                    + "bottom, split by owner. Let me know if I've missed anything."),
        .single(id: "t19", hoursAgo: 42, from: priya, subject: "Invoice INV-1042 attached",
                snippet: "This month's invoice is attached — net 30 as usual.",
                body: "This month's invoice is attached — net 30 as usual. Thanks again for the "
                    + "quick turnaround on the last round of feedback.",
                attachment: AttachmentMeta(
                    id: "t19-att1", filename: "INV-1042.pdf", mimeType: "application/pdf", size: 96_000)),
        .single(id: "t20", hoursAgo: 68, from: priya, subject: "Quick sanity check on the numbers",
                snippet: "Before I send these out, can you double-check the totals on slide 6?",
                unread: true),

        // MARK: Team (domain rule: northwind.example) — 5 threads

        .single(id: "t21", hoursAgo: 7, from: maya, subject: "Sprint planning notes",
                snippet: "Notes from planning are up — we pulled in two extra tickets for the sprint.",
                unread: true),
        ThreadSeed(
            id: "t22", hoursAgo: 24,
            messages: [
                .init(from: jonah, subject: "Deploy checklist",
                      snippet: "Can you confirm the checklist before we cut the release?"),
                .init(from: jonah, subject: "Re: Deploy checklist",
                      snippet: "Updated — final version, ready to go whenever you are.",
                      body: "Updated checklist — final version, ready to go whenever you are. "
                          + "Rollback steps are on the second page just in case.",
                      extraLabels: ["UNREAD"]),
            ]),
        .single(id: "t23", hoursAgo: 48, from: northwindFinance, subject: "Expense report approved",
                snippet: "Your expense report for last month has been approved and will be reimbursed.",
                body: "Your expense report for last month has been approved and will be reimbursed "
                    + "on the next pay cycle. No further action needed."),
        .single(id: "t24", hoursAgo: 75, from: maya, subject: "Design review — Thursday 2pm",
                snippet: "Moved the design review to Thursday at 2pm — same room.",
                body: "Moved the design review to Thursday at 2pm, same room. Bring whatever's "
                    + "ready — doesn't need to be final.",
                unread: true),
        .single(id: "t25", hoursAgo: 96, from: jonah, subject: "Server migration — status update",
                snippet: "Migration is about 80% done — on track to finish by end of week.",
                body: "Migration is about 80% done — on track to finish by end of week. Flagging one "
                    + "service that needs a config change before we can cut over fully."),

        // MARK: Updates (CATEGORY_UPDATES) — 5 threads

        .single(id: "t26", hoursAgo: 3, from: codepine, subject: "3 new comments on your pull request",
                snippet: "Someone left feedback on \"Fix pagination edge case\".", unread: true,
                category: "CATEGORY_UPDATES"),
        .single(id: "t27", hoursAgo: 12, from: novaFitness, subject: "Your weekly activity summary",
                snippet: "You logged 4 workouts this week — your best streak in a month.",
                body: "You logged 4 workouts this week — your best streak in a month. Keep it up "
                    + "and you'll hit your monthly goal by Friday.",
                category: "CATEGORY_UPDATES"),
        .single(id: "t28", hoursAgo: 21, from: dailyLoom, subject: "This week in your neighborhood",
                snippet: "A new bakery opened downtown, and the library extended its weekend hours.",
                body: "A new bakery opened downtown, and the library extended its weekend hours. "
                    + "Full roundup of this week's local news below.",
                category: "CATEGORY_UPDATES"),
        .single(id: "t29", hoursAgo: 30, from: cinderpeakBank, subject: "Security alert: new sign-in detected",
                snippet: "We noticed a new sign-in to your account from a device we don't recognize.",
                body: "We noticed a new sign-in to your account from a device we don't recognize. "
                    + "If this was you, no action is needed — otherwise, reset your password at "
                    + "https://cinderpeak.example/security right away.",
                unread: true, category: "CATEGORY_UPDATES"),
        .single(id: "t30", hoursAgo: 39, from: pixelHarborSupport, subject: "Your subscription renews in 7 days",
                snippet: "Your annual plan renews on the 18th — no changes needed on your end.",
                category: "CATEGORY_UPDATES"),

        // MARK: Promotions (CATEGORY_PROMOTIONS) — 5 threads

        // A real HTML newsletter — remote hero image + CTA link — so the demo
        // exercises the WKWebView path: the image stays BLOCKED behind "Load
        // remote images" by default, and "Shop the sale" opens in the browser.
        .single(id: "t31", hoursAgo: 6, from: fernwoodMarket, subject: "Late-summer sale: 30% off everything",
                snippet: "Thirty percent off sitewide, through the weekend only.",
                body: "Late-summer sale: 30% off everything, sitewide, through the weekend only. "
                    + "Shop the sale at https://fernwood.example/sale",
                html: "<div style=\"font-family:sans-serif;max-width:520px\">"
                    + "<h1 style=\"color:#b5651d;margin:0 0 8px\">Late-summer sale</h1>"
                    + "<p style=\"font-size:16px\"><strong>30% off everything</strong> — "
                    + "sitewide, through the weekend only.</p>"
                    + "<img src=\"https://cdn.fernwood.example/hero-summer.jpg\" alt=\"Summer collection\" "
                    + "width=\"480\" style=\"border-radius:8px;margin:8px 0\">"
                    + "<p><a href=\"https://fernwood.example/sale\" "
                    + "style=\"background:#b5651d;color:#fff;padding:10px 18px;border-radius:6px;"
                    + "text-decoration:none;display:inline-block\">Shop the sale &rarr;</a></p>"
                    + "<p style=\"color:#888;font-size:12px\">Fernwood Market · 100 Market St · "
                    + "<a href=\"https://fernwood.example/unsubscribe\">Unsubscribe</a></p></div>",
                unread: true, category: "CATEGORY_PROMOTIONS"),
        .single(id: "t32", hoursAgo: 15, from: glasswingStudio, subject: "New arrivals just dropped",
                snippet: "This week's collection is live — first look before it goes to the main site.",
                category: "CATEGORY_PROMOTIONS"),
        .single(id: "t33", hoursAgo: 23, from: harborRoast, subject: "Free shipping this weekend only",
                snippet: "No minimum, no code needed — free shipping on every order through Sunday.",
                unread: true, category: "CATEGORY_PROMOTIONS"),
        .single(id: "t34", hoursAgo: 31, from: driftwoodOutfitters, subject: "Your cart misses you",
                snippet: "You left a few things behind — they're still in stock, for now.",
                category: "CATEGORY_PROMOTIONS"),
        .single(id: "t35", hoursAgo: 40, from: lumenHome, subject: "Last chance: 24 hours left",
                snippet: "The seasonal sale wraps up tomorrow night — everything's still 20% off.",
                category: "CATEGORY_PROMOTIONS"),

        // MARK: Social (CATEGORY_SOCIAL) — 5 threads

        .single(id: "t36", hoursAgo: 1, from: buzzline, subject: "You have 4 new notifications",
                snippet: "3 replies and a new follower since you last checked.", unread: true,
                category: "CATEGORY_SOCIAL"),
        .single(id: "t37", hoursAgo: 10, from: frontPorch, subject: "Your neighbors are talking about the new park",
                snippet: "12 new posts in your neighborhood this week.", category: "CATEGORY_SOCIAL"),
        .single(id: "t38", hoursAgo: 19, from: handshakeNetwork, subject: "5 people viewed your profile this week",
                snippet: "See who's been checking out your profile and reach out.",
                category: "CATEGORY_SOCIAL"),
        .single(id: "t39", hoursAgo: 28, from: ridgelineRunClub, subject: "New route shared in your group",
                snippet: "A new 8-mile loop was just added to the group — highly rated so far.",
                body: "A new 8-mile loop was just added to the group — highly rated so far, "
                    + "mostly flat with one climb near mile 5.",
                unread: true, category: "CATEGORY_SOCIAL"),
        .single(id: "t40", hoursAgo: 37, from: orbitPhotos, subject: "3 new memories from this week",
                snippet: "Some favorites from a year ago just resurfaced in your library.",
                starred: true, category: "CATEGORY_SOCIAL"),
    ]
}

/// One `saveBody` call's arguments, collected by `ThreadSeed.expand` and
/// applied after every thread's snapshots have been written.
private typealias BodySave = (messageID: String, body: SanitizedBody, attachments: [AttachmentMeta])

/// One synthetic conversation's raw ingredients. `expand` is the ONLY place
/// this talks to `Store`'s vocabulary — turning invented text into real
/// `MessageSnapshot`s and `saveBody` arguments.
private struct ThreadSeed: Sendable {
    /// One message within the thread, oldest listed first.
    struct Message: Sendable {
        let from: String
        let subject: String
        let snippet: String
        let body: String?
        /// Optional raw HTML for this message. When present it's stored as the
        /// message's `raw_html` (with `body` kept as the plain-text fallback),
        /// so the reading pane exercises the real WKWebView HTML path — remote
        /// images blocked by default, links clickable. Every URL below is a
        /// fictional `.example` domain, so nothing actually loads or leaks.
        let html: String?
        let attachment: AttachmentMeta?
        /// Beyond the automatic "INBOX" (added to every non-SENT message):
        /// "UNREAD", "STARRED", "SENT", or a "CATEGORY_*" id.
        let extraLabels: [String]
        /// Overrides the default `to` (the demo account) — used for the
        /// "You" reply messages, addressed back to the thread's contact.
        let to: String?

        init(
            from: String, subject: String, snippet: String, body: String? = nil,
            html: String? = nil, attachment: AttachmentMeta? = nil, extraLabels: [String] = [],
            to: String? = nil
        ) {
            self.from = from
            self.subject = subject
            self.snippet = snippet
            self.body = body
            self.html = html
            self.attachment = attachment
            self.extraLabels = extraLabels
            self.to = to
        }
    }

    let id: String
    /// Age, in hours before `now`, of the NEWEST message. Earlier messages
    /// in a multi-message thread are spaced ~20h further back from there.
    let hoursAgo: Double
    let messages: [Message]

    /// Convenience for the common one-message thread.
    static func single(
        id: String, hoursAgo: Double, from: String, subject: String, snippet: String,
        body: String? = nil, html: String? = nil, attachment: AttachmentMeta? = nil,
        unread: Bool = false, starred: Bool = false, category: String? = nil
    ) -> ThreadSeed {
        var labels: [String] = []
        if unread { labels.append("UNREAD") }
        if starred { labels.append("STARRED") }
        if let category { labels.append(category) }
        return ThreadSeed(
            id: id, hoursAgo: hoursAgo,
            messages: [
                Message(from: from, subject: subject, snippet: snippet, body: body,
                        html: html, attachment: attachment, extraLabels: labels)
            ])
    }

    /// Expands into snapshots (oldest -> newest) and any body/attachment
    /// saves. `historyID`s derive purely from `threadIndex`/message
    /// position — unique per message id and never random, per each
    /// message id only ever being applied once by this seed.
    func expand(
        threadIndex: Int, now: Date, account: String
    ) -> (snapshots: [MessageSnapshot], bodySaves: [BodySave]) {
        var snapshots: [MessageSnapshot] = []
        var bodySaves: [BodySave] = []
        let count = messages.count
        for (position, message) in messages.enumerated() {
            let ageHours = hoursAgo + Double(count - 1 - position) * 20
            let internalDate = Int64(now.addingTimeInterval(-ageHours * 3600).timeIntervalSince1970 * 1000)
            let messageID = "\(id)-m\(position)"
            let historyID = Int64(threadIndex * 10 + position + 1)

            let isSent = message.extraLabels.contains("SENT")
            var labelIDs = isSent ? [] : ["INBOX"]
            labelIDs.append(contentsOf: message.extraLabels)

            snapshots.append(
                MessageSnapshot(
                    id: messageID, threadID: id, historyID: historyID, internalDate: internalDate,
                    fromLine: message.from, toLine: message.to ?? account, subject: message.subject,
                    snippet: message.snippet, labelIDs: labelIDs))

            if message.body != nil || message.html != nil {
                // Build the body through the real sanitizer factory rather than
                // fabricating a `SanitizedBody` — that keeps the §3.5 invariant
                // that a `SanitizedBody` only ever comes out of `Sanitizer`.
                // With `html: nil` this yields a plain-text-only body; when a
                // message provides HTML, the sanitizer keeps the raw HTML and
                // catalogues its remote URLs, so the reading pane exercises the
                // real WKWebView path (with `body` as the plain-text fallback).
                let htmlData = message.html.map { Data($0.utf8) }
                let body = Sanitizer.sanitize(html: htmlData, plainText: message.body)
                let attachments = message.attachment.map { [$0] } ?? []
                bodySaves.append((messageID: messageID, body: body, attachments: attachments))
            }
        }
        return (snapshots, bodySaves)
    }
}
