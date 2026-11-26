import Foundation

// TGeshka: unit test of the easter egg (пасхалка), every case of the [tests] section in
// tgeshka-easter-egg.txt. Runs on Linux without Xcode, see .github/workflows/easter-egg.yml:
//   swiftc -warnings-as-errors submodules/TelegramCore/Sources/TGeshka/TGeshkaEasterEggRules.swift \
//     Tests/TGeshkaEasterEgg/main.swift -o easter_egg_tests && ./easter_egg_tests tgeshka-easter-egg.txt

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tgeshka-easter-egg.txt"
guard let data = FileManager.default.contents(atPath: path), let content = String(data: data, encoding: .utf8) else {
    print("FAIL: cannot read \(path)")
    exit(1)
}
let rules = TGeshkaEasterEggRules(content: content)
if rules.names.isEmpty || rules.insults.isEmpty || rules.replacement.isEmpty || rules.tests.isEmpty {
    print("FAIL: empty rules or tests")
    exit(1)
}
var failed = 0
for (input, expected) in rules.tests {
    let output = rules.apply(input) ?? input
    if output != expected {
        failed += 1
        print("FAIL: '\(input)' -> '\(output)', expected '\(expected)'")
    }
}
if rules.apply("просто текст") != nil {
    failed += 1
    print("FAIL: text without a match must give nil")
}
print("\(rules.tests.count + 1 - failed) of \(rules.tests.count + 1) cases passed")
exit(failed == 0 ? 0 : 1)
