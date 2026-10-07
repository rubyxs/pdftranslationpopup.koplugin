# PDF Translation Popup for KOReader

Add tappable popup notes, Chinese translations, and movable dots or emoji faces to PDFs in KOReader. Version **2.4.1**. The current plugin interface is in Chinese.

## Install

1. Download this repository using **Code → Download ZIP** and extract it.
2. Rename the extracted directory to `pdftranslationpopup.koplugin`.
3. Copy that directory into your KOReader `plugins/` directory. The resulting path must be `koreader/plugins/pdftranslationpopup.koplugin/main.lua`.
4. Restart KOReader and open a PDF. Find **PDF 中文弹窗** in the document menu.

Alternatively, clone directly into your KOReader plugins directory:

```sh
git clone https://github.com/rubyxs/pdftranslationpopup.koplugin.git pdftranslationpopup.koplugin
```

## Quick start

- Use **添加圆点模式 → 进入／退出添加模式** to enter add mode, tap the PDF page, and enter a note. Use **表情…** to choose a face.
- Tap an existing marker to read its popup; in add mode, tap it to edit its text or face.
- Long-press a marker and tap another position on the same page to move it.
- Turn off PDF text reflow before adding or moving markers.
- Close the document normally to embed changes in the PDF before sharing it. Pending edits are saved in the KOReader sidecar while the document is open.

This plugin displays text you enter or annotations already stored in the PDF; it does not automatically translate documents. Recipients need this plugin in KOReader to see the custom markers and popups. Adding and embedding edits requires a writable PDF.

## License and source

The plugin was extracted from [rubyxs/koreader](https://github.com/rubyxs/koreader/tree/6ddffef2583fab5f172d4b2663f86e96ee965354/plugins/pdftranslationpopup.koplugin), retaining the source repository's [GNU AGPL v3 license](LICENSE). Bundled OpenMoji SVG artwork is separately licensed under CC BY-SA 4.0; see [OPENMOJI.md](OPENMOJI.md).

## Detailed behavior: PDF 中文弹窗 v2.4.1

Runtime-drawn/repositionable circles and OpenMoji face markers for `KOPOPZH2` PDFs.

## Editing interaction

You can leave **圆点编辑模式** enabled while reading:

- Short tap a circle: open its translation.
- Short tap elsewhere: normal KOReader behavior (e.g. page turn).
- Long-press a circle: select it for moving; it becomes black.
- Next short tap on the same page: place it there.
- Other long-press actions are consumed while edit mode is enabled.

Enable **添加圆点模式** to create annotations directly in a writable PDF:

- Short tap an empty spot on the page and enter the annotation text. The **表情…** button below the text box opens a paged grid of OpenMoji SVG faces; choosing one returns to the text box. Canceling the grid also returns to the text box. Tap **添加** to save.
- Short tap an existing circle to edit its face and text in the same dialog. Older `KOPOPZH1` circles support text changes only because their icon is baked into the PDF.
- Long-press an existing `KOPOPZH2` circle, then tap a new position on the same page to move it. Add mode exits after the move is saved.
- The new circle appears at the tapped position and opens its text when tapped.
- Add mode exits automatically after an add or edit dialog is saved or canceled, restoring normal short-tap page navigation.
- The dispatcher action **PDF 中文弹窗：添加圆点** enters add mode and can be assigned to a gesture.
- Entering add mode shows a brief notification at the top of the screen.
- PDF text reflow must be off because reflowed coordinates cannot be mapped back to a native PDF annotation.
- New annotations and text edits remain in memory until the document closes. They are journaled immediately in the KOReader sidecar, then embedded together with pending marker positions in one small incremental PDF update.
- Sleeping leaves the PDF open and keeps its changes in memory. If KOReader stops unexpectedly, pending annotations are replayed from the sidecar when the book opens again. A normal restart closes the book and embeds them first.
- Under **添加圆点模式 → 自定义表情默认大小**, choose 18, 24, or 30 size units for newly added faces. Each marker keeps its chosen size in the PDF. The 34-unit touch region stays the same.

## Storage model in v2.2

Marker movement now uses a journal + batched PDF writeback model:

1. Every move/reset is saved immediately to the KOReader sidecar.
2. The sidecar entry is marked pending/dirty.
3. While the document remains open, moves, resets, additions, and text/emoji edits are journaled in the sidecar.
4. On a clean document close, all pending positions and annotation edits are appended to the PDF in one incremental update. The result is reopened and checked before sidecar positions are cleared.
5. Only after that PDF write succeeds are those pending sidecar overrides cleared.
6. If the PDF is read-only or saving fails, the pending sidecar data is retained for the next open.

This makes the PDF itself the durable/portable copy after a clean close, while the sidecar protects pending changes against a crash before close.

Embedded format:

```text
KOPOPZH2
@KOPOP_POS 412.123456 183.654321
@KOPOP_EMOJI 1F642
@KOPOP_EMOJI_SIZE 24
<translation text>
```

The position and emoji metadata lines are optional. Existing plain dots and older annotations remain readable. Editing text and moving/resetting a marker preserve its selected face and size.

The original annotation geometry stays unchanged; only the plugin-rendered marker/touch position is overridden.

Close the document normally to embed changes. The former **立即写入 PDF** action is unavailable because writing twice from one open MuPDF document can corrupt its cross-reference chain.

## v2.0/v2.1 sidecar migration

Existing sidecar positions from older plugin versions are automatically treated as pending, because those versions never embedded positions in the PDF. They will be written into the PDF on the next clean close.

## Reset behavior

Resetting a marker is also journaled. At the next PDF flush its `@KOPOP_POS` line is removed, so the marker returns to the converter-defined anchor position. Reset-current-visible-pages and reset-whole-book both support already-embedded positions.

## Compatibility

- `KOPOPZH2`: runtime circle + repositioning + embedded position metadata.
- `KOPOPZH2` with `@KOPOP_EMOJI`: runtime OpenMoji face with the same touch/popup behavior.
- `KOPOPZH1`: readable, but its baked circle cannot be repositioned cleanly; reconvert with the v2 converter first.

The 126 bundled black SVGs are from OpenMoji. See [OPENMOJI.md](OPENMOJI.md) for attribution and license.
