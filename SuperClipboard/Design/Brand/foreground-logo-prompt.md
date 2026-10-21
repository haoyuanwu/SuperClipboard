# Transparent colored foreground

Edited with the built-in image_gen tool. Master: `SuperClipboard-logo-foreground.png`. Used by `MenuBarLogo.imageset` at 18, 36, and 54 pixels, with original rendering to retain color.

The Dock uses `SuperClipboard/SuperClipboardIcon.icon`, a native macOS icon package with an opaque blue gradient beneath the edge-to-edge logo artwork. This replaces the legacy AppIcon selection so macOS can apply its enclosure without an extra fallback tile.

## Edit prompt

Edit target: the attached SuperClipboard logo. Background-extraction / precise-object-edit. Keep ONLY the central clipboard and the two stacked cards behind it as one isolated foreground mark. Completely REMOVE the large blue rounded-square background tile, its blue/cyan swoosh shapes, every piece of the tile, its perimeter shadow, and all stray edge pixels. The background outside the clipboard/cards must be truly transparent. Keep the clipboard's white paper, cyan/blue clip with round hole, three blue horizontal text strokes, and blue/cyan rear cards, preserving their exact shape, colors and arrangement. The circle hole in the clip should be transparent. Retain crisp shapes, simplify only excessive shadows for readability at macOS menu bar size. Center the isolated clipboard/cards, enlarge to fill around 94% of the square canvas height, and retain narrow transparent padding so it never clips. No blue tile, no square base, no white backdrop, no text, no new objects. This is the full-color foreground layer and colored menu bar icon, not a monochrome template.
