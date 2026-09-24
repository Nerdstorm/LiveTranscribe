import Foundation

/// Lists spoken with markers ("number one …, number two …", "bullet point … bullet point …"),
/// whose markers ``ListMarkerCommand`` has already turned into "1. " and "- " at the start of
/// lines: the line before gets its colon, the items their capitals and full stops (see
/// ``ListStyle``), and any sentence after the last item starts a new paragraph.
public struct MarkedListLayout: LayoutRule {
    private let style: ListStyle

    public init(style: ListStyle = ListStyle()) {
        self.style = style
    }

    public func arrange(_ lines: [String]) -> [String]? {
        var result: [String] = []
        var index = 0
        var changed = false
        while index < lines.count {
            guard let first = ListStyle.marker(of: lines[index]) else {
                result.append(lines[index])
                index += 1
                continue
            }
            var prefixes: [String] = []
            var texts: [String] = []
            while index < lines.count, let marker = ListStyle.marker(of: lines[index]), marker.isNumbered == first.isNumbered {
                prefixes.append(marker.prefix)
                texts.append(String(lines[index].dropFirst(marker.prefix.count)))
                index += 1
            }
            if let previous = result.last, ListStyle.marker(of: previous) == nil, let leadIn = style.leadIn(previous) {
                result[result.count - 1] = leadIn
            }
            var after: String?
            if let split = ListStyle.splitAfterFirstSentence(texts[texts.count - 1]) {
                texts[texts.count - 1] = split.sentence
                after = split.rest
            }
            result += zip(prefixes, style.items(texts)).map { $0 + $1 }
            // What follows the list starts a paragraph, unless it is the next item said inline.
            if let after { result += ListStyle.marker(of: after) == nil ? ["", after] : [after] }
            changed = true
        }
        return changed ? result : nil
    }
}

/// Lists spoken with ordinals ("first, …; second, …") or cardinals ("one is …, two is …"), found
/// in each line of prose by ``ListFormatter``. Lines that are already list items are left alone.
public struct OrdinalListLayout: LayoutRule {
    private let formatter: ListFormatter

    public init(formatter: ListFormatter = ListFormatter()) {
        self.formatter = formatter
    }

    public func arrange(_ lines: [String]) -> [String]? {
        var result: [String] = []
        var changed = false
        for line in lines {
            if ListStyle.marker(of: line) == nil, let list = formatter.lines(for: line) {
                result += list
                changed = true
            } else {
                result.append(line)
            }
        }
        return changed ? result : nil
    }
}
