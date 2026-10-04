import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import MangaTLCore

@Suite struct TypesetterTests {
    let balloon = CGRect(x: 0, y: 0, width: 360, height: 240)
    let text = "I can't believe you actually came all the way out here just to see me tonight"

    func style(_ edit: (inout TextStyle) -> Void = { _ in }) -> TextStyle {
        var s = TextStyle()
        s.fontName = "Helvetica"
        edit(&s)
        return s
    }

    @Test func balloonTextFormsADiamond() throws {
        let layout = try #require(Typesetter.layout(text, in: balloon, shape: .ellipse, style: style(), scale: 1))
        #expect(!layout.overflow)
        #expect(layout.lines.count >= 3)
        // Widest line in the middle third, the first and last narrower than it.
        let widths = layout.lines.map(\.width)
        let widest = widths.indices.max { widths[$0] < widths[$1] }!
        let third = Double(widths.count) / 3
        #expect(Double(widest) >= third - 1 && Double(widest) <= 2 * third)
        #expect(widths.first! < widths[widest] && widths.last! < widths[widest])
        // Every line fits its available width (the ellipse at that height).
        for (line, room) in zip(layout.lines, layout.available) { #expect(line.width <= room + 0.5) }
        // Every word is kept, in order.
        #expect(layout.lines.map(\.text).joined(separator: " ") == text)
    }

    @Test func plainWordWrapWouldSpillOutOfTheBalloon() throws {
        let layout = try #require(Typesetter.layout(text, in: balloon, shape: .ellipse, style: style(), scale: 1))
        // The old behaviour: greedy wrap across the full box width at the same size.
        let font = Typesetter.font(style(), size: layout.fontSize)
        let space = Typesetter.measure(" ", font: font)
        var greedy: [CGFloat] = [], current: CGFloat = 0
        for word in text.split(separator: " ").map(String.init) {
            let w = Typesetter.measure(word, font: font)
            if current > 0 && current + space + w > layout.box.width { greedy.append(current); current = 0 }
            current += (current > 0 ? space : 0) + w
        }
        greedy.append(current)
        // Room each greedy line would have inside the ellipse at its height.
        let geometry = Typesetter.Geometry(box: layout.box, shape: .ellipse, alignment: .center)
        let n = greedy.count
        let rooms = (0..<n).map { k -> CGFloat in
            let top = layout.box.midY + CGFloat(n) * layout.lineAdvance / 2 - CGFloat(k) * layout.lineAdvance
            return geometry.width(from: top - layout.lineAdvance, to: top)
        }
        #expect(zip(greedy, rooms).contains { $0 > $1 + 0.5 }, "greedy wrap pokes outside the curve")
        #expect(zip(layout.lines.map(\.width), layout.available).allSatisfy { $0 <= $1 + 0.5 }, "diamond stays inside")
    }

    @Test func fixedSizeThatCannotFitIsFlagged() throws {
        let layout = try #require(Typesetter.layout(text, in: CGRect(x: 0, y: 0, width: 80, height: 40), shape: .ellipse,
                                                    style: style { $0.fontSize = 30 }, scale: 1))
        #expect(layout.overflow)
    }

    @Test func hyphenatesOnlyLongWordsAndOnlyOnce() {
        let font = Typesetter.font(style(), size: 20)
        let long = Typesetter.Token(text: "extraordinarily", width: Typesetter.measure("extraordinarily", font: font), breakAfter: false)
        let short = Typesetter.Token(text: "tiny", width: Typesetter.measure("tiny", font: font), breakAfter: false)
        let split = Typesetter.hyphenate([long, short], limit: 60, font: font)
        #expect(split.count == 3)
        #expect(split[0].text.hasSuffix("-") && split[0].breakAfter)
        #expect(split[0].text.dropLast() + split[1].text == "extraordinarily")
        #expect(split[2].text == "tiny", "short words are never hyphenated")
    }

    @Test func tallerScaleUsesLessRoomVertically() throws {
        let normal = try #require(Typesetter.layout(text, in: balloon, shape: .ellipse, style: style(), scale: 1))
        let tall = try #require(Typesetter.layout(text, in: balloon, shape: .ellipse, style: style { $0.verticalScale = 1.3 }, scale: 1))
        #expect(tall.box.height < normal.box.height)
        #expect(tall.box.height * 1.3 <= balloon.height)
    }

    @Test func whisperIsSmallerThanTheFittedSize() throws {
        let normal = try #require(Typesetter.layout("Psst, over here", in: balloon, shape: .ellipse, style: style(), scale: 1))
        let whisper = try #require(Typesetter.layout("Psst, over here", in: balloon, shape: .ellipse,
                                                     style: TextRole.whisper.preset(from: style()), scale: 1))
        #expect(whisper.fontSize < normal.fontSize * 0.9)
    }
}

@Suite struct RoleAndStyleTests {
    @Test(arguments: [
        ("おい！！", "Hey!!", true, TextRole.shout),
        ("（どうしよう…）", "(What do I do...)", true, .thought),
        ("こんにちは", "Hello there", true, .dialogue),
        ("ドン", "BOOM", false, .sfx),
        ("その日、街は静かだった。", "That day, the town was quiet.", false, .narration),
    ])
    func guessesRole(source: String, translation: String, inBubble: Bool, expected: TextRole) {
        #expect(PagePipeline.guessRole(source: source, translation: translation, inBubble: inBubble) == expected)
    }

    @Test func styleLookupOrder() {
        var settings = ProjectSettings()
        settings.style.color = RGBA(0.1, 0.2, 0.3)
        var block = TextBlock(textRect: .zero, layoutRect: .zero, shape: .ellipse, sourceText: "", translation: "x")
        #expect(settings.resolvedStyle(for: block) == settings.style, "dialogue uses the project style")
        block.role = .thought
        #expect(settings.resolvedStyle(for: block).italic, "role preset")
        var custom = settings.style
        custom.fontSize = 40
        settings.roleStyles = [.thought: custom]
        #expect(settings.resolvedStyle(for: block).fontSize == 40, "edited role preset")
        var own = settings.style
        own.uppercase = true
        block.style = own
        #expect(settings.resolvedStyle(for: block).uppercase, "block style wins")
    }

    @Test func oldProjectFilesStillDecode() throws {
        // A v0.1.0 style/settings JSON without the new fields.
        let json = #"{"language":"ja","rightToLeft":true,"style":{"fontName":"CCWildWordsRoman","color":{"r":0,"g":0,"b":0,"a":1},"strokeColor":{"r":1,"g":1,"b":1,"a":1},"strokeWidth":3,"alignment":"center","lineHeight":1.05,"uppercase":false}}"#
        let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data(json.utf8))
        #expect(settings.style.strokeWidth == 3 && settings.style.padding == 0.12 && settings.style.verticalScale == 1)
        #expect(settings.roleStyles == nil)
        let roundTrip = try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip == settings)
        // Role-keyed presets encode as a JSON object.
        var withPresets = settings
        withPresets.roleStyles = [.shout: TextRole.shout.preset(from: settings.style)]
        let encoded = String(decoding: try JSONEncoder().encode(withPresets), as: UTF8.self)
        #expect(encoded.contains(#""roleStyles":{"shout""#))
    }
}
