import Foundation

/// A calendar event or a Granola note is typed by somebody else — whoever sent the invite, or
/// whoever spoke — and is stored as it was synced. Everything that hands one on (the timeline, the
/// MCP tools, the blocks built from it) takes it through `TextRedactor` first, and before any
/// length cap, so a cut can never leave half a credential standing.
extension ContextEvent {
    /// The event with its title, body and outcomes redacted. Participants are kept: an address
    /// is not a credential, and `TextRedactor` keeps emails everywhere else too.
    public func redacted(with redactor: TextRedactor = TextRedactor()) -> ContextEvent {
        var event = self
        event.title = redactor.redactIfPresent(title).text
        event.bodyMd = redactor.redactIfPresent(bodyMd).text
        if let outcomes {
            event.outcomesJson = outcomes.redacted(with: redactor).encoded
        }
        return event
    }
}

extension MeetingOutcomes {
    /// Every item's text and detail through `redactor`; `namesYou` and the order stay.
    public func redacted(with redactor: TextRedactor) -> MeetingOutcomes {
        func clean(_ item: Item) -> Item {
            var item = item
            item.text = redactor.redact(item.text).text
            item.detail = redactor.redactIfPresent(item.detail).text
            return item
        }
        var out = self
        out.nextSteps = nextSteps.map(clean)
        out.decisions = decisions.map(clean)
        return out
    }
}
