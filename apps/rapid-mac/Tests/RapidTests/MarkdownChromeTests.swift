import AppKit
import Testing

@testable import Rapid

@Suite("Markdown chrome appearance")
struct MarkdownChromeTests {
    @Test("Code and table chrome resolve to distinct light and dark palettes")
    func dynamicChromeColors() throws {
        let options = MarkdownOptions()

        #expect(try rgb(options.codeBlockBackground, in: .aqua) == [0xF1, 0xF0, 0xEC])
        #expect(try rgb(options.codeBlockBackground, in: .darkAqua) == [0x1A, 0x1D, 0x21])
        #expect(try rgb(#require(options.codeBlockBorder), in: .aqua) == [0xE0, 0xE0, 0xDC])
        #expect(try rgb(#require(options.codeBlockBorder), in: .darkAqua) == [0x2E, 0x32, 0x38])
        #expect(try rgb(#require(options.tableHeaderBackgroundColor), in: .aqua)
            == [0xF1, 0xF1, 0xEF])
        #expect(try rgb(#require(options.tableHeaderBackgroundColor), in: .darkAqua)
            == [0x22, 0x25, 0x2A])
        #expect(try rgb(#require(options.tableBorderColor), in: .aqua) == [0xE0, 0xE0, 0xDC])
        #expect(try rgb(#require(options.tableBorderColor), in: .darkAqua) == [0x2E, 0x32, 0x38])
    }

    @MainActor
    @Test("A live code block repaints its layer when appearance changes")
    func codeBlockRepaintsWithoutReconstruction() throws {
        let options = MarkdownOptions()
        let view = MarkdownCodeBlockView(options: options)
        view.appearance = NSAppearance(named: .aqua)
        view.configure(code: "let answer = 42", language: "swift", options: options)
        #expect(try rgb(#require(view.layer?.backgroundColor), in: .aqua)
            == [0xF1, 0xF0, 0xEC])
        #expect(try rgb(#require(view.layer?.borderColor), in: .aqua)
            == [0xE0, 0xE0, 0xDC])

        view.appearance = NSAppearance(named: .darkAqua)
        view.viewDidChangeEffectiveAppearance()
        #expect(try rgb(#require(view.layer?.backgroundColor), in: .darkAqua)
            == [0x1A, 0x1D, 0x21])
        #expect(try rgb(#require(view.layer?.borderColor), in: .darkAqua)
            == [0x2E, 0x32, 0x38])
    }

    private func rgb(_ color: NSColor, in appearanceName: NSAppearance.Name) throws -> [Int] {
        let appearance = try #require(NSAppearance(named: appearanceName))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB)
        }
        let device = try #require(resolved)
        return [device.redComponent, device.greenComponent, device.blueComponent].map {
            Int(($0 * 255).rounded())
        }
    }

    private func rgb(_ color: CGColor, in appearanceName: NSAppearance.Name) throws -> [Int] {
        try rgb(#require(NSColor(cgColor: color)), in: appearanceName)
    }
}
