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
| Card gap | 12 pt |
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
- Main category targets are 24 × 28 pt within their capsule, keeping the new entry on the same toolbar row at the existing 420–460 pt window width. Search, notebook and utility targets remain 32 pt.
- Empty notebook copy explains the history context-menu entry. Settings groups the directory, migration action and persistence explanation together in the scrollable form.
- Isolated fixture UI checked: main toolbar, empty and populated notebook, right-click save, and settings directory layout. Popover controls and copy actions were inspected in the accessibility tree.
- `Scripts/test_notebook.sh` exercises source-independent storage, rich text, same-name files, source removal, cleanup, copying, restart, migration and failure protection using temporary directories and a private pasteboard.
