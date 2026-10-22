# List scrolling performance — 2026-10-22

## Work removed from card rendering

- Images and RTF are decoded on a dedicated actor, with cancellation checks for rows that scroll away. The worker serializes decoding so quick scrolling cannot spawn an unbounded set of decoders.
- The shared preview cache has a 64 MiB cost target and 180-entry count limit. Rows release their decoded preview when they disappear. Image previews are generated with ImageIO at card display resolution; original payloads remain available to detail/copy/archive operations.
- Card RTF text storage is bounded to a composed-character-safe prefix of approximately 12,000 UTF-16 units. Complete original text remains in the store and clipboard. Light/dark styling is prepared once per cached preview.
- Rich text layout measurements are cached per width and height limit; the list measures only its visible text height. Source app icons, logo colors, sort results and date formatters are reused.
- The main list now uses a direct lazy stack. Each list computes its filtered snapshot once per body evaluation.
- Hover shadows follow a rounded rectangle rather than rendering a shadow from all text/image layers. Press-release tasks are created only for actual clicks.

## Synthetic loading benchmark

Run `Scripts/test_scroll_performance.sh`.

Fixture: 4096 × 3072 RGB image and long styled RTF. Local optimized test binary, 20 repeated loads:

| Metric | Result |
| --- | ---: |
| Previous synchronous read/import/decode path | 173.74 ms total |
| New cold preview, including both appearance styles | 72.29 ms |
| Warm cached previews | 0.28 ms total |
| Source image bitmap storage | 37,748,736 bytes |
| List thumbnail bitmap storage | 2,764,800 bytes |

These are synthetic decode/cache measurements, not scroll frame-rate or application RSS measurements. Cold loading still takes work, but it executes away from the UI actor.

## Validation

- Debug build passes with the existing macOS 14 deployment target.
- Decoder checks cover thumbnail dimensions, rich-text colors/backgrounds, Unicode-safe truncation, cache reuse, revision changes and cancellation.
- Notebook regression tests also check list previews after original file removal and cached sorting after copy-count and pin changes.
- Isolated native UI with 600 mixed records: continuous 20-page downward scroll and return scroll; images, text colors, white rich-text canvas and metadata render correctly. No private clipboard contents were used.
