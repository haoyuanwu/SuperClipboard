"""Measure the actual Swift/AppKit palette used by this macOS UI."""
from pathlib import Path
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
content = (root / 'SuperClipboard/ContentView.swift').read_text()
section = 'enum LibrarySection:' + content.split('enum LibrarySection:', 1)[1].split('struct ContentView:', 1)[0]
source = (root / 'SuperClipboard/ClipboardTheme.swift').read_text() + '\n'
source += (root / 'SuperClipboard/ClipboardTextAppearance.swift').read_text() + '\n' + section
source += r'''
var measurements: [[String: Any]] = []
func resolved(_ color: NSColor) -> NSColor { color.usingColorSpace(.deviceRGB)! }
func luminance(_ color: NSColor) -> Double {
    let c = resolved(color)
    func linear(_ n: CGFloat) -> Double {
        let v = Double(n)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
}
func compose(_ foreground: NSColor, _ background: NSColor) -> NSColor {
    let a = resolved(foreground), b = resolved(background), opacity = a.alphaComponent
    return NSColor(deviceRed: a.redComponent * opacity + b.redComponent * (1 - opacity),
                   green: a.greenComponent * opacity + b.greenComponent * (1 - opacity),
                   blue: a.blueComponent * opacity + b.blueComponent * (1 - opacity), alpha: 1)
}
func measure(_ name: String, _ foreground: NSColor, _ background: NSColor, _ minimum: Double) {
    let a = luminance(compose(foreground, background)), b = luminance(background)
    let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
    measurements.append(["name": name, "ratio": ratio, "minimum": minimum, "passed": ratio >= minimum])
}
for dark in [false, true] {
    let mode = dark ? "dark" : "light"
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        let page = resolved(NSColor(ClipboardTheme.pageBackground))
        let header = resolved(NSColor(ClipboardTheme.headerBackground))
        let group = compose(NSColor(ClipboardTheme.controlFill), header)
        measure("\(mode)/body", NSColor(ClipboardTheme.primary), page, 4.5)
        measure("\(mode)/caption", NSColor(ClipboardTheme.secondary), page, 4.5)
        measure("\(mode)/toolbar", NSColor(ClipboardTheme.toolbarAccent), header, 3)
        measure("\(mode)/focus", NSColor(ClipboardTheme.focusRing), group, 3)
        measure("\(mode)/copy-action", NSColor(ClipboardTheme.actionForeground), NSColor(ClipboardTheme.actionFill), 4.5)
        measure("\(mode)/copied-feedback", NSColor(ClipboardTheme.successText), NSColor(ClipboardTheme.successFill), 4.5)
        measure("\(mode)/destructive-action", NSColor(ClipboardTheme.dangerText), page, 4.5)
        for (name, backdrop) in [("black", NSColor.black), ("white", NSColor.white)] {
            let search = compose(NSColor(ClipboardTheme.popoverSearchFill), backdrop)
            let glassHeader = compose(NSColor(ClipboardTheme.popoverHeaderFill), backdrop)
            measure("\(mode)/glass-search/\(name)/text", NSColor(ClipboardTheme.primary), search, 4.5)
            measure("\(mode)/glass-search/\(name)/placeholder", NSColor(ClipboardTheme.secondary), search, 4.5)
            measure("\(mode)/glass-search/\(name)/glyph", NSColor(ClipboardTheme.secondary), search, 3)
            measure("\(mode)/glass-header/\(name)/toolbar", NSColor(ClipboardTheme.toolbarAccent), glassHeader, 3)
        }
        for section in [LibrarySection.all, .text, .image, .file, .video] {
            let tint = resolved(NSColor(dark ? section.tint : section.lightTint))
            for state in ["default", "hover", "selected"] {
                let selected = state == "selected", hovered = state == "hover"
                let opacity: CGFloat = dark ? (selected ? 0.20 : (hovered ? 0.30 : 0.07)) : (selected ? 1 : (hovered ? 0.18 : 0.09))
                let background = compose(tint.withAlphaComponent(opacity), group)
                let label = !dark && selected ? NSColor.white : NSColor(ClipboardTheme.primary)
                measure("\(mode)/category/\(section.rawValue)/\(state)", label, background, 4.5)
            }
        }
        for (index, tint) in [NSColor.black, .white, .red, .green, .blue, .orange, .purple, .gray].enumerated() {
            for (endpoint, card) in ClipboardCardPalette.gradient(tint: tint, isDark: dark).enumerated() {
                measure("\(mode)/card-\(index)-\(endpoint)/text", NSColor(ClipboardTheme.cardPrimary), card, 4.5)
                measure("\(mode)/card-\(index)-\(endpoint)/metadata", NSColor(ClipboardTheme.cardSecondary), card, 4.5)
                measure("\(mode)/card-\(index)-\(endpoint)/hover", NSColor(ClipboardTheme.hoverBorder), card, 3)
                measure("\(mode)/card-\(index)-\(endpoint)/focus", NSColor(ClipboardTheme.focusRing), card, 3)
            }
        }
    }
}
let data = try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
'''
with tempfile.TemporaryDirectory(prefix='SuperClipboard-ui-check-') as directory:
    swift = Path(directory) / 'check.swift'
    swift.write_text(source)
    result = subprocess.run(['swift', str(swift)], capture_output=True, text=True, check=True)
    rows = json.loads(result.stdout)
report = {'measuredPairs': len(rows), 'passed': all(row['passed'] for row in rows), 'measurements': rows}
(root / 'Design/UI/contrast-report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
failures = [row for row in rows if not row['passed']]
print(f"Contrast: {len(rows) - len(failures)}/{len(rows)} measured pairs passed")
for row in failures:
    print(f"{row['name']}: {row['ratio']:.3f} < {row['minimum']}")
raise SystemExit(bool(failures))
