import AppKit
import LibrettoEngine

extension PageEditor {
    // MARK: - Where comments are

    func refreshCommentRanges() {
        let ranges = CommentAnchors.ranges(in: storage, trailing: trailingMarkers)
        guard ranges != commentRanges else { return }
        let changed = Array(commentRanges.values) + Array(ranges.values)
        commentRanges = ranges
        layoutManager.commentRanges = Array(ranges.values)
        redraw(changed)
    }

    private func redraw(_ ranges: [NSRange]) {
        for range in ranges {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
            if clamped.length > 0 { layoutManager.invalidateDisplay(forCharacterRange: clamped) }
        }
    }

    /// The comments on the text at the selection, in the comments part's order.
    func publishSelectedComments() {
                let selection = self.selection
        let touched = commentRanges.filter { _, range in
            guard range.length > 0 else { return false }
            if selection.length == 0 {
                return selection.location >= range.location && selection.location <= NSMaxRange(range)
            }
            return NSIntersectionRange(range, selection).length > 0
        }
        let order = Dictionary(document.comments.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = touched.keys.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
        if state.selectedCommentIDs != ids { state.selectedCommentIDs = ids }
        let active = Array(touched.values)
        if active != layoutManager.activeCommentRanges {
            let changed = layoutManager.activeCommentRanges + active
            layoutManager.activeCommentRanges = active
            redraw(changed)
        }
    }

    /// The text a comment is on, shortened to a line.
    func commentQuote(_ id: String) -> String? {
        guard let range = commentRanges[id], NSMaxRange(range) <= storage.length else { return nil }
        let text = (storage.string as NSString).substring(with: range)
            .replacingOccurrences(of: TextCharacters.lineBreak, with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: TextCharacters.attachment, with: "")
            .trimmed
        return text.count > 140 ? String(text.prefix(140)) + "…" : text
    }

    /// Selects the text a comment is on and brings it into view.
    func selectComment(_ id: String) {
        guard let range = commentRanges[id] else { return }
        self.selection = range
        selectionDidChange()
        textView.scrollRangeToVisible(range)
    }

    // MARK: - Adding, changing and removing

    /// Comments on the selection, or on the word at the caret.
    func addComment(_ text: String) {
        var range = selection
        if range.length == 0, storage.length > 0 {
            let word = textView.selectionRange(forProposedRange: range, granularity: .selectByWord)
            if word.length > 0, !(storage.string as NSString).substring(with: word).trimmed.isEmpty { range = word }
        }
        guard range.length > 0 else { return }
        let comment = Comment(
            id: document.unusedCommentID(), author: Reviewer.name, initials: Reviewer.initials, date: Reviewer.now,
            text: text, paraID: document.unusedCommentParaID()
        )
        anchor(comment, to: range)
        self.selection = NSRange(location: NSMaxRange(range), length: 0)
        finishCommentEdit()
    }

    /// Replies to a comment, on the same text.
    func reply(to parentID: String, text: String) {
        guard let index = document.comments.firstIndex(where: { $0.id == parentID }) else { return }
        if document.comments[index].paraID == nil { document.comments[index].paraID = document.unusedCommentParaID() }
        let parent = document.comments[index]
        var reply = Comment(
            id: document.unusedCommentID(), author: Reviewer.name, initials: Reviewer.initials, date: Reviewer.now,
            text: text, paraID: document.unusedCommentParaID()
        )
        reply.parentParaID = parent.paraID
        anchor(reply, to: commentRanges[parentID] ?? selection)
        finishCommentEdit()
    }

    private func anchor(_ comment: Comment, to range: NSRange) {
        let referenceStyle = document.styles.styles["CommentReference"] != nil ? "CommentReference" : nil
        storage.beginEditing()
        attach([CommentAnchors.start(comment.id)], at: range.location, nearText: true)
        attach(CommentAnchors.end(comment.id, referenceStyleID: referenceStyle), at: NSMaxRange(range), nearText: false)
        storage.endEditing()
        document.comments.append(comment)
    }

    /// Puts markers on the character at `location`, which they come before:
    /// next to it, or before any markers already there.
    func attach(_ markers: [Inline], at location: Int, nearText: Bool) {
        guard location < storage.length else {
            trailingMarkers = nearText ? trailingMarkers + markers : markers + trailingMarkers
            return
        }
        let character = (storage.string as NSString).rangeOfComposedCharacterSequence(at: location)
        let existing = (storage.attribute(.librettoMarkers, at: location, effectiveRange: nil) as? MarkersBox)?.markers ?? []
        storage.addAttribute(
            .librettoMarkers, value: MarkersBox(nearText ? existing + markers : markers + existing), range: character
        )
    }

    /// Resolves a comment, and its replies with it, or opens them again.
    func setCommentDone(_ id: String, _ isDone: Bool) {
        guard let index = document.comments.firstIndex(where: { $0.id == id }) else { return }
        if document.comments[index].paraID == nil { document.comments[index].paraID = document.unusedCommentParaID() }
        let paraID = document.comments[index].paraID
        for other in document.comments.indices
        where document.comments[other].id == id || document.comments[other].parentParaID == paraID {
            if document.comments[other].paraID == nil {
                document.comments[other].paraID = document.unusedCommentParaID()
            }
            document.comments[other].isDone = isDone
        }
        finishCommentEdit()
    }

    func editComment(_ id: String, text: String) {
        guard let index = document.comments.firstIndex(where: { $0.id == id }) else { return }
        document.comments[index].text = text
        finishCommentEdit()
    }

    /// Deletes a comment, its replies, and the markers that tie them to the text.
    func deleteComment(_ id: String) {
        guard let comment = document.comments.first(where: { $0.id == id }) else { return }
        var ids: Set<String> = [id]
        if let paraID = comment.paraID {
            for reply in document.comments where reply.parentParaID == paraID { ids.insert(reply.id) }
        }
        document.comments.removeAll { ids.contains($0.id) }
        func keeps(_ inline: Inline) -> Bool {
            CommentAnchors.marker(inline).map { !ids.contains($0.id) } ?? true
        }
        var changes: [(NSRange, [Inline])] = []
        storage.enumerateAttribute(.librettoMarkers, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let box = value as? MarkersBox else { return }
            let kept = box.markers.filter(keeps)
            if kept.count != box.markers.count { changes.append((range, kept)) }
        }
        storage.beginEditing()
        for (range, kept) in changes {
            if kept.isEmpty {
                storage.removeAttribute(.librettoMarkers, range: range)
            } else {
                storage.addAttribute(.librettoMarkers, value: MarkersBox(kept), range: range)
            }
        }
        storage.endEditing()
        trailingMarkers = trailingMarkers.filter(keeps)
        finishCommentEdit()
    }

    private func finishCommentEdit() {
        relayout()
        sync(scope: .comment)
        selectionDidChange()
    }

    // MARK: - Recording

    /// Turns tracking changes on or off, a setting saved with the document.
    func setTracking(_ isOn: Bool) {
        flush()
        document.trackRevisions = isOn
        onChange?(document, .review)
        selectionDidChange()
    }

    /// Takes out or replaces text while changes are tracked: rather than
    /// going, it is marked deleted, apart from what this reviewer inserted in
    /// the first place, which simply goes. The replacement goes in after it.
    func trackedChange(in range: NSRange, replacement: String) {
        let deletion = Revision(kind: .deletion, author: Reviewer.name, date: revisionDate)
        let selection = self.selection
        let isBackspace = replacement.isEmpty && selection.length == 0 && selection.location == NSMaxRange(range)
        var removed = 0
        storage.beginEditing()
        // Back to front, so the characters still to come stay where they are.
        var index = NSMaxRange(range) - 1
        while index >= range.location {
            let character = (storage.string as NSString).rangeOfComposedCharacterSequence(at: index)
            index = character.location - 1
            if storage.attribute(.librettoBlock, at: character.location, effectiveRange: nil) != nil
                || storage.attribute(.attachment, at: character.location, effectiveRange: nil) is BlockAttachment {
                continue
            }
            let box = storage.attribute(.librettoRun, at: character.location, effectiveRange: nil) as? RunBox
            switch box?.revision?.kind {
            case .insertion? where box?.revision?.author == Reviewer.name:
                storage.deleteCharacters(in: character)
                removed += character.length
            case .deletion?, .moveFrom?:
                continue
            default:
                storage.addAttribute(
                    .librettoRun,
                    value: RunBox(box?.format ?? RunFormat(), hyperlink: box?.hyperlink, revision: deletion),
                    range: character
                )
            }
        }
        let end = NSMaxRange(range) - removed
        var caret = isBackspace ? range.location : end
        if !replacement.isEmpty {
            let attributes = typingAttributes(at: end)
            storage.insert(NSAttributedString(string: replacement, attributes: attributes), at: end)
            caret = end + (replacement as NSString).length
        }
        DocumentRenderer.restyle(
            storage, paragraphsIn: NSRange(location: range.location, length: max(0, caret - range.location)),
            finalParagraph: finalParagraph, context: context
        )
        storage.endEditing()
        self.selection = NSRange(location: min(caret, storage.length), length: 0)
        textDidChange(touchingParagraphs: true)
    }

    // MARK: - Reviewing

    /// The tracked change at the selection: the whole run of text marked as the same change.
    func revisionRange(around location: Int) -> NSRange? {
        for index in [location, location - 1] where index >= 0 && index < storage.length {
            guard let revision = (storage.attribute(.librettoRun, at: index, effectiveRange: nil) as? RunBox)?.revision
            else { continue }
            func same(_ at: Int) -> Bool {
                (storage.attribute(.librettoRun, at: at, effectiveRange: nil) as? RunBox)?.revision == revision
            }
            var start = index
            var end = index + 1
            while start > 0, same(start - 1) { start -= 1 }
            while end < storage.length, same(end) { end += 1 }
            return NSRange(location: start, length: end - start)
        }
        return nil
    }

    /// Accepts or rejects the changes in the selection, or the change at the caret.
    func resolveChange(accept: Bool) {
        let selection = self.selection
        guard let range = selection.length > 0 ? selection : revisionRange(around: selection.location) else { return }
        storage.beginEditing()
        var index = NSMaxRange(range) - 1
        var end = NSMaxRange(range)
        while index >= range.location {
            let character = (storage.string as NSString).rangeOfComposedCharacterSequence(at: index)
            index = character.location - 1
            guard let box = storage.attribute(.librettoRun, at: character.location, effectiveRange: nil) as? RunBox,
                  let revision = box.revision else { continue }
            if accept == revision.kind.adds {
                storage.addAttribute(.librettoRun, value: RunBox(box.format, hyperlink: box.hyperlink), range: character)
            } else {
                storage.deleteCharacters(in: character)
                end -= character.length
            }
        }
        DocumentRenderer.restyle(
            storage, paragraphsIn: NSRange(location: range.location, length: max(0, end - range.location)),
            finalParagraph: finalParagraph, context: context
        )
        storage.endEditing()
        self.selection = NSRange(location: min(end, storage.length), length: 0)
        relayout()
        sync(scope: .review)
        selectionDidChange()
    }

    /// Accepts or rejects every change in the document, tables and formatting changes among them.
    func resolveAllChanges(accept: Bool) {
        flush()
        document.body = Revisions.resolve(document.body, accept: accept)
        commitDocument(scope: .review)
    }

    /// Selects the next tracked change after the selection, or the one before it.
    func selectChange(forward: Bool) {
        let selection = self.selection
        var found: NSRange?
        storage.enumerateAttribute(
            .librettoRun, in: NSRange(location: 0, length: storage.length), options: forward ? [] : [.reverse]
        ) { value, range, stop in
            guard (value as? RunBox)?.revision != nil else { return }
            let isAhead = forward ? range.location >= NSMaxRange(selection) && range.location > selection.location
                : NSMaxRange(range) <= selection.location
            guard isAhead else { return }
            found = revisionRange(around: forward ? range.location : NSMaxRange(range) - 1)
            stop.pointee = true
        }
        guard let found else { return }
        self.selection = found
        selectionDidChange()
        textView.scrollRangeToVisible(found)
    }

    /// How many tracked changes the document has, counting each run of one as one.
    var changeCount: Int {
        var count = 0
        var last: Revision?
        storage.enumerateAttribute(.librettoRun, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            let revision = (value as? RunBox)?.revision
            if let revision, revision != last { count += 1 }
            last = revision
        }
        return count
    }
}
