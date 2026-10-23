# SuperClipboard UI refinement

## Direction

A compact macOS clipboard library: the copied content is the focal point; logo-colored cards identify source apps; utility controls remain quiet and grouped. Preserve the narrow single-column window, full-color logo, rich-text source formatting, and copy-without-reordering behavior.

## Skills installed and applied

- `software-ui-design`: reusable token specification and validation report.
- `ui-design`: spacing, typography hierarchy, interaction states, focus indicators and reduced motion.
- `perceptual-ui-design-epoch2018`: grouping, actual-size review, long content and surface-specific color measurements.

The skills are installed in the project's `skills/` directory and in `~/.codex/skills/`.

## Shared tokens

| Token | Value |
| --- | --- |
| List outer inset | 16 pt |
| Card inset | 16 pt |
| Card gap | 14 pt |
| Card radius | 16 pt |
| Inner content radius | 12 pt |
| Toolbar utility target | 32 pt |
| Toolbar radius | 10 pt |
| Pointer transition | 160 ms |
| Default content | 14 pt, native system interface font |
| Metadata | 12 pt, tabular count digits |

The native system font is retained intentionally for compact macOS interface legibility. Copied fonts, colors, paragraph styles and document backgrounds remain source-owned. Compact desktop pointer targets retain the user's narrow toolbar instead of adopting the web skill's mobile 44 pt layout.

## Changes

- Categories form one capsule group, separate from search/sort and settings/about.
- Utility buttons share hover, press, disabled and keyboard-focus treatments.
- Main and popover cards share padding, radius, gap and metadata typography.
- Copy counts use an icon and VoiceOver label; source name and icon remain on the right.
- Detail footer groups source and timestamp on two lines, keeping the copy action at bottom-right.
- Settings separates appearance and history controls; clear-history uses a destructive color.
- Reduced-motion settings disable optional scale and hover animations.

## Validation

- `python3 Design/UI/validate-design.py`: **172/172** foreground/background pairs pass their measured thresholds. Text requires 4.5:1; control glyphs, focus and hover borders require 3:1. Covers both themes, category default/hover/selected states and card gradient endpoints for eight representative logo colors. Results are in `contrast-report.json`.
- macOS Debug build succeeds with Xcode.
- Actual app screenshots reviewed for light and dark main window, long filenames, full-path detail, source/count footer and grouped settings. The original system appearance preference was restored after review.
- The final destructive-color and hover-border adjustments were compiled and measured; their final running appearance still requires the next app launch. Popover uses the same card and button components; a final popover screenshot was not captured in this pass.

## Scope of evidence

Contrast results apply to app-owned colors. User-provided rich-text colors and backgrounds are preserved, so their contrast depends on the copied source. Screenshot review is qualitative; it is not a VoiceOver or full keyboard-navigation audit.

## Notebook addition

- The book icon toggles between clipboard history and an independent saved list in both surfaces. The active icon uses the existing toolbar accent and control fill; no new palette was introduced.
- The main window keeps its existing 420–460 pt width. Its toolbar now separates search and utility actions from labeled category filters and sorting, giving the controls room without widening the window.
- Empty notebook copy explains the history context-menu entry. Settings groups the directory, migration action and persistence explanation together in the scrollable form.
- Isolated fixture UI checked: main toolbar, empty and populated notebook, right-click save, and settings directory layout. Popover controls and copy actions were inspected in the accessibility tree.
- `Scripts/test_notebook.sh` exercises source-independent storage, rich text, same-name files, source removal, cleanup, copying, restart, migration and failure protection using temporary directories and a private pasteboard.

## Popover glass — 2026-10-22

- A single regular Liquid Glass surface covers the panel on macOS 26, with a restrained light tint or smoke tint for dark mode. macOS 14/15 use ultra-thin material. Card content retains its existing opaque gradient surfaces.
- Search uses an adaptive readability veil; its placeholder no longer adds extra transparency. Utility controls sit on a lighter/darker adaptive header veil. Native popover windows use a clear background so an opaque window fill does not cover the material.
- Reduce Transparency and Increased Contrast select the existing solid page background. This avoids nesting expensive glass layers inside the scrolling cards.
- Contrast validation now measures 188 pairs, including search text/placeholder/icons and header controls against both black and white underlying backdrops in light/dark appearance. All pass. The system-rendered glass itself depends on backdrop and system preferences; the measured veil bounds do not assert a fixed glass color.
- Isolated native preview checked in both light and dark appearance, including search, utility icons, copied counts and rich-text canvas.
- API availability checked against the local macOS SDK and Apple's documentation: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views

## Compact window hierarchy

- The main window uses a 46 pt title and action row above a 42 pt filter row. Category names stay visible; sorting sits at the end of the filter row. Search expansion keeps the utility actions available.
- The status bar popover keeps its 390 × 520 pt frame. Search and window actions occupy the first glass row; history/notebook modes and the visible count occupy a second row. The selected mode uses a distinct surface and a short spring transition.
- Category labels use neutral foregrounds on tinted controls. The updated contrast check requires 4.5:1 for these labels and passes 188/188 measured pairs across light and dark appearances.
- Main window screenshots were inspected at actual size with search both collapsed and expanded. The visible popover states still need a live screenshot check in the menu bar surface.

## Overall UI refinement — 2026-10-23

Applied `ui-ux-pro-max` to the macOS SwiftUI product. The initial design-system search returned a web-oriented product-demo pattern; it was rejected for this desktop utility. The narrower glassmorphism style result and SwiftUI Form guidance support the retained native font, SF Symbols, glass shells and grouped settings. Mobile touch-size and viewport rules do not substitute for desktop pointer dimensions.

- Main toolbar retains its compact 420–460 pt width. Title/count share a hierarchy; settings and About are in a labeled More menu. The title row is 52 pt, filters remain 42 pt.
- The 390 × 520 pt status panel puts history/notebook navigation and utility groups first, then a full-width search field and count. Quit remains a distinct power button with its existing glass confirmation.
- List rhythm uses 16 pt outer/card insets and a 14 pt gap. A subtle divider separates content from metadata. File cards have a 44 pt icon tile; list media previews are capped at 176 pt. Original rich-text formatting remains preserved.
- Settings retain native grouped Form controls, with symbolled section headers, shorter explanations, a consistent close target and a 480 pt scrollable sheet. About shares the typography hierarchy.
- Shelf header/footer use bounded adaptive readability surfaces; the main shelf retains its translucent shell. Footer explains drag in/out and delayed clearing together.
- Shared hover/press feedback is restrained (card press 0.985, hover 1.003); keyboard focus and Reduce Motion remain supported. The opaque button-style backing was removed so shelf cards keep their transparency.

Validation: isolated fixture app with a private clipboard and temporary storage reviewed for main, expanded search, status panel, quit/cancel, grouped settings and shelf in light/dark mode. No user records were used. Numeric contrast report includes shelf chrome and selected modes; it does not claim fixed contrast for arbitrary system-rendered glass or copied source formatting. Drag/import regression and lifecycle checks pass. Full VoiceOver operation and multi-display drag are outside this visual refinement pass.
