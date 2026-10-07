#!/usr/bin/env python3
"""Convert PDF text-note translations for pdftranslationpopup.koplugin v2.

The source PDF is expected to contain ``/Text`` annotations whose ``/Contents``
hold the translations. For every such note this tool:

* keeps the original ``/Text`` annotation as hidden metadata (so conversion is
  safely repeatable) but removes any baked appearance, including v1 circles;
* adds a fully transparent ``/Highlight`` annotation containing a ``KOPOPZH2``
  payload understood by ``pdftranslationpopup.koplugin``;
* leaves all visible marker drawing to the KOReader plugin, which means marker
  positions can be changed later without modifying the PDF.

The conversion is safe to run again. Generated v1/v2 hitboxes are removed and
rebuilt without duplication. Old v1 converted PDFs can therefore be migrated
simply by running this v2 converter over them.
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

from pypdf import PdfReader, PdfWriter
from pypdf.generic import (
    ArrayObject,
    BooleanObject,
    DictionaryObject,
    FloatObject,
    NameObject,
    NumberObject,
    TextStringObject,
)


MARKER_V2 = "KOPOPZH2\n"
MARKER_V1 = "KOPOPZH1\n"
GENERATED_MARKERS = (MARKER_V2, MARKER_V1)

# Annotation flag bits from ISO 32000. Hidden + NoView makes the retained text
# notes metadata-only for ordinary viewing, while keeping them available for a
# future re-conversion.
ANNOT_HIDDEN = 1 << 1
ANNOT_NO_VIEW = 1 << 5
HIDDEN_FLAGS = ANNOT_HIDDEN | ANNOT_NO_VIEW


def _number(value: float) -> FloatObject:
    return FloatObject(round(float(value), 4))


def _rect(values: tuple[float, float, float, float]) -> ArrayObject:
    return ArrayObject([_number(value) for value in values])


def _page_bounds(page) -> tuple[float, float, float, float]:
    box = page.cropbox if page.cropbox else page.mediabox
    return tuple(float(value) for value in box)


def _centered_box(
    center_x: float,
    center_y: float,
    diameter: float,
    page_bounds: tuple[float, float, float, float] | None = None,
) -> tuple[float, float, float, float]:
    half = diameter / 2
    x1, y1, x2, y2 = (
        center_x - half,
        center_y - half,
        center_x + half,
        center_y + half,
    )
    if page_bounds:
        page_x1, page_y1, page_x2, page_y2 = page_bounds
        x1, y1 = max(x1, page_x1), max(y1, page_y1)
        x2, y2 = min(x2, page_x2), min(y2, page_y2)
    return x1, y1, x2, y2


def _is_generated_highlight(annotation) -> bool:
    if str(annotation.get("/Subtype")) != "/Highlight":
        return False
    contents = str(annotation.get("/Contents", ""))
    return any(contents.startswith(marker) for marker in GENERATED_MARKERS)


def _hide_source_text_note(annotation) -> None:
    """Retain a source /Text note but make it invisible and non-interactive."""
    existing_flags = int(annotation.get("/F", 0) or 0)
    annotation[NameObject("/F")] = NumberObject(existing_flags | HIDDEN_FLAGS)
    annotation[NameObject("/Open")] = BooleanObject(False)

    # v1 stored the visible circle here. Removing /AP is important when a v1
    # PDF is fed back through this converter: the old circle must disappear.
    annotation.pop(NameObject("/AP"), None)


def _make_hit_annotation(
    writer: PdfWriter,
    bounds: tuple[float, float, float, float],
    translation: str,
    page_number: int,
    note_number: int,
):
    x1, y1, x2, y2 = bounds
    annotation = DictionaryObject(
        {
            NameObject("/Type"): NameObject("/Annot"),
            NameObject("/Subtype"): NameObject("/Highlight"),
            NameObject("/Rect"): _rect(bounds),
            # PDF highlight quad order: upper-left, upper-right, lower-left,
            # lower-right. KOReader/MuPDF exposes this as a box whose center is
            # the default marker anchor.
            NameObject("/QuadPoints"): ArrayObject(
                [
                    _number(x1),
                    _number(y2),
                    _number(x2),
                    _number(y2),
                    _number(x1),
                    _number(y1),
                    _number(x2),
                    _number(y1),
                ]
            ),
            NameObject("/Contents"): TextStringObject(MARKER_V2 + translation),
            # Fully transparent: KOReader draws the visible circle itself.
            NameObject("/C"): ArrayObject(
                [FloatObject(1), FloatObject(1), FloatObject(0)]
            ),
            NameObject("/CA"): FloatObject(0),
            NameObject("/F"): NumberObject(4),
            NameObject("/NM"): TextStringObject(
                f"KOPOPZH2-page-{page_number}-note-{note_number}"
            ),
            NameObject("/KOReaderTranslationHitbox"): BooleanObject(True),
            NameObject("/KOReaderDrawMarker"): BooleanObject(True),
        }
    )
    return writer._add_object(annotation)


def convert_pdf(
    input_path: Path,
    output_path: Path,
    *,
    tap_diameter: float,
) -> tuple[int, int]:
    if input_path.resolve() == output_path.resolve():
        raise ValueError("Input and output paths must be different.")
    if tap_diameter <= 0:
        raise ValueError("Tap diameter must be greater than zero.")

    reader = PdfReader(str(input_path))
    if reader.is_encrypted and not reader.decrypt(""):
        raise ValueError(
            "The input PDF is encrypted and cannot be opened without a password."
        )

    writer = PdfWriter()
    writer.clone_document_from_reader(reader)

    converted = 0
    removed_generated = 0

    for page_number, page in enumerate(writer.pages, start=1):
        annotations = page.get("/Annots")
        if not annotations:
            continue

        kept_annotations = ArrayObject()
        text_notes: list[tuple[object, str, tuple[float, float, float, float]]] = []

        for annotation_ref in list(annotations):
            annotation = annotation_ref.get_object()

            if _is_generated_highlight(annotation):
                removed_generated += 1
                continue

            kept_annotations.append(annotation_ref)

            if str(annotation.get("/Subtype")) == "/Text":
                contents = str(annotation.get("/Contents", "")).strip()
                note_rect = annotation.get("/Rect")
                if contents and note_rect and len(note_rect) == 4:
                    text_notes.append(
                        (annotation, contents, tuple(float(v) for v in note_rect))
                    )
                    _hide_source_text_note(annotation)

        page[NameObject("/Annots")] = kept_annotations
        page_bounds = _page_bounds(page)

        for note_number, (_annotation, contents, note_rect) in enumerate(
            text_notes, start=1
        ):
            center_x = (note_rect[0] + note_rect[2]) / 2
            center_y = (note_rect[1] + note_rect[3]) / 2

            hit_box = _centered_box(
                center_x,
                center_y,
                tap_diameter,
                page_bounds=page_bounds,
            )
            kept_annotations.append(
                _make_hit_annotation(
                    writer,
                    hit_box,
                    contents,
                    page_number,
                    note_number,
                )
            )
            converted += 1

    if converted == 0:
        raise ValueError(
            "No non-empty /Text annotations were found in the input PDF. "
            "Use the original annotated PDF, or a v1/v2 converted PDF that "
            "still contains the retained /Text notes."
        )

    metadata = {
        key: str(value)
        for key, value in (reader.metadata or {}).items()
        if key != "/Title" and value is not None and str(value) != "NullObject"
    }
    metadata["/Subject"] = (
        "PDF text-note translations with KOReader plugin-rendered popup markers"
    )
    writer.add_metadata(metadata)
    # Keep the old converter's behavior: don't invent viewer-specific titles.
    writer._info.get_object().pop(NameObject("/Title"), None)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            prefix=f".{output_path.stem}.",
            suffix=".tmp",
            dir=output_path.parent,
            delete=False,
        ) as stream:
            temp_name = stream.name
            writer.write(stream)
        os.replace(temp_name, output_path)
    finally:
        if temp_name and os.path.exists(temp_name):
            os.unlink(temp_name)

    return converted, removed_generated


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Convert PDF /Text translation notes into KOReader-compatible "
            "KOPOPZH2 anchors. Visible circles are drawn by the KOReader plugin."
        )
    )
    parser.add_argument("input_pdf", type=Path, help="Annotated source PDF")
    parser.add_argument("output_pdf", type=Path, help="Converted PDF to create")
    parser.add_argument(
        "--tap-diameter",
        type=float,
        default=34.0,
        metavar="PT",
        help=(
            "Transparent anchor box size in PDF points (default: 34). "
            "The plugin uses its own screen-sized touch target."
        ),
    )
    # Backward-compatible no-op: older commands may still pass this option.
    parser.add_argument(
        "--icon-diameter",
        type=float,
        default=None,
        metavar="PT",
        help=(
            "Legacy v1 option; accepted for compatibility but ignored because "
            "v2 circles are drawn by the KOReader plugin."
        ),
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Replace an existing output file",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    input_path = args.input_pdf.expanduser()
    output_path = args.output_pdf.expanduser()

    if not input_path.is_file():
        parser.error(f"input PDF does not exist: {input_path}")
    if output_path.exists() and not args.force:
        parser.error(f"output already exists (use --force): {output_path}")

    try:
        converted, removed = convert_pdf(
            input_path,
            output_path,
            tap_diameter=args.tap_diameter,
        )
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    rerun_note = (
        f"; replaced {removed} old generated v1/v2 anchors" if removed else ""
    )
    print(
        f"Converted {converted} text notes -> {output_path}{rerun_note}. "
        "Visible circles will be drawn by pdftranslationpopup.koplugin v2."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
