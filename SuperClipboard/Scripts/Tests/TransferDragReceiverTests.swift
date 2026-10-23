import AppKit

@main
struct TransferDragReceiverTests {
    @MainActor static func main() {
        var policy = TransferDragHintPolicy()
        policy.begin(changeCount: 10)
        func visible(_ generation: Int, down: Bool = true, files: Bool = true, own: Bool = false, ready: Bool = true) -> Bool {
            policy.shouldShow(buttonDown: down, changeCount: generation, hasFiles: files, isTransfer: own, canAccept: ready)
        }
        precondition(!visible(10), "Retained URLs from an earlier drag must not show the hint")
        precondition(visible(11), "New external file drags must show the target")
        precondition(!visible(11, files: false), "Dragging text must not show a file target")
        precondition(!visible(11, own: true), "Shelf children and groups must not re-enter through the global target")
        precondition(!visible(11, ready: false), "Do not offer a destination while saving another group")
        precondition(!visible(11, down: false), "Mouse release must dismiss the target")
        policy.consume()
        precondition(!visible(12), "Late callbacks after a drop must not revive the target")
        policy.begin(changeCount: 12)
        precondition(!visible(12) && visible(13), "A fresh mouse gesture may show a new file session")
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 875),
                       NSRect(x: -1920, y: 100, width: 1920, height: 1055),
                       NSRect(x: 500, y: 900, width: 2560, height: 1400)]
        for screen in screens {
            let hint = TransferDragHintPolicy.frame(in: screen)
            precondition(screen.contains(hint))
            precondition(hint.maxX == screen.maxX - 16 && hint.maxY == screen.maxY - 16,
                         "Position relative to the selected display, including negative origins")
        }
        print("PASS: fresh file gesture detection, stale/text/internal/busy drag rejection, release/late callback reset and multi-display target placement")
    }
}
