import Foundation

// TGeshka: easter egg (пасхалка) in outgoing messages. The rule and the words live in
// tgeshka-easter-egg.txt at the repository root, the same file in all three TGeshka clients.
// Foundation only, so the unit test (Tests/TGeshka/TGeshkaEasterEggTest.swift) runs on Linux.
public struct TGeshkaEasterEggRules: Sendable {
    public var names: [[UInt16]] = []
    public var fillers: [[UInt16]] = []
    public var insults: [[UInt16]] = []
    public var replacement: String = ""
    public var maxSuffix: Int = 0
    public var tests: [(String, String)] = []

    public init() {
    }

    public init(content: String) {
        var section = ""
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }
            switch section {
            case "names":
                self.names.append(TGeshkaEasterEggRules.normalize(Array(line.utf16)))
            case "fillers":
                self.fillers.append(TGeshkaEasterEggRules.normalize(Array(line.utf16)))
            case "insults":
                self.insults.append(TGeshkaEasterEggRules.normalize(Array(line.utf16)))
            case "replacement":
                self.replacement = line
            case "max_suffix":
                self.maxSuffix = Int(line) ?? 0
            case "tests":
                if let arrow = line.range(of: " => ") {
                    self.tests.append((String(line[line.startIndex ..< arrow.lowerBound]), String(line[arrow.upperBound...])))
                }
            default:
                break
            }
        }
    }

    // The text with every match replaced, or nil if nothing matched.
    public func apply(_ text: String) -> String? {
        let chars = Array(text.utf16)
        var result: [UInt16] = []
        var copied = 0
        var replaced = false
        var position = 0
        while position < chars.count {
            if !TGeshkaEasterEggRules.isWordChar(chars[position]) {
                position += 1
                continue
            }
            let end = TGeshkaEasterEggRules.wordEnd(chars, position)
            let tail = self.names.contains(self.word(chars, position, end)) ? self.matchTail(chars, end) : 0
            if tail == 0 {
                position = end
                continue
            }
            result.append(contentsOf: chars[copied ..< position])
            let name = TGeshkaEasterEggRules.isUpper(chars[position]) ? "Костя " : "костя "
            result.append(contentsOf: Array((name + self.replacement).utf16))
            copied = tail
            position = tail
            replaced = true
        }
        if !replaced {
            return nil
        }
        result.append(contentsOf: chars[copied...])
        return String(decoding: result, as: UTF16.self)
    }

    private func matchTail(_ chars: [UInt16], _ from: Int) -> Int {
        var position = TGeshkaEasterEggRules.skipSeparators(chars, from)
        var end = TGeshkaEasterEggRules.wordEnd(chars, position)
        if end > position && self.fillers.contains(self.word(chars, position, end)) {
            position = TGeshkaEasterEggRules.skipSeparators(chars, end)
            end = TGeshkaEasterEggRules.wordEnd(chars, position)
        }
        var result = 0
        while end > position && self.isInsult(self.word(chars, position, end)) {
            result = end
            position = TGeshkaEasterEggRules.skipSeparators(chars, end)
            end = TGeshkaEasterEggRules.wordEnd(chars, position)
        }
        return result
    }

    private func isInsult(_ word: [UInt16]) -> Bool {
        for root in self.insults {
            if word.count >= root.count && word.count - root.count <= self.maxSuffix && word.starts(with: root) {
                return true
            }
        }
        return false
    }

    private func word(_ chars: [UInt16], _ from: Int, _ till: Int) -> [UInt16] {
        return TGeshkaEasterEggRules.normalize(Array(chars[from ..< till]))
    }

    private static func wordEnd(_ chars: [UInt16], _ from: Int) -> Int {
        var position = from
        while position < chars.count && isWordChar(chars[position]) {
            position += 1
        }
        return position
    }

    private static func skipSeparators(_ chars: [UInt16], _ from: Int) -> Int {
        var position = from
        while position < chars.count && isSeparator(chars[position]) {
            position += 1
        }
        return position
    }

    private static func normalize(_ word: [UInt16]) -> [UInt16] {
        return word.map { c in
            if (c >= 0x41 && c <= 0x5A) || (c >= 0x0410 && c <= 0x042F) {
                return c + 32
            } else if c == 0x0401 || c == 0x0451 {
                return 0x0435
            }
            return c
        }
    }

    private static func isUpper(_ c: UInt16) -> Bool {
        return (c >= 0x41 && c <= 0x5A) || (c >= 0x0410 && c <= 0x042F) || c == 0x0401
    }

    private static func isWordChar(_ c: UInt16) -> Bool {
        return (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || (c >= 0x0400 && c <= 0x04FF)
    }

    private static func isSeparator(_ c: UInt16) -> Bool {
        return c == 0x20 || c == 0x09 || c == 0xA0 || c == 0x2C || c == 0x2D || c == 0x2013 || c == 0x2014
    }
}
