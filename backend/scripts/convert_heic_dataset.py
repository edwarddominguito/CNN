"""Read-only audit by default; --prepare creates fresh JPEG staging, never promotes.

Run with backend/.venv/Scripts/python.exe. Example from the project root:
  backend/.venv/Scripts/python.exe backend/scripts/convert_heic_dataset.py --prepare \
    --supplement-dir "C:/path/to/photos" --supplement-class Poor-Quality-Rice-Mix \
    --supplement-batch batch_01

A supplement is one physical sample and can ONLY fill an existing empty batch.
Existing outputs are refused, not overwritten. Sources are always read-only.
"""

import argparse
import csv
import hashlib
import json
import re
import shutil
import tempfile
import warnings
from collections import Counter, defaultdict
from pathlib import Path

from PIL import Image, ImageOps
import pillow_heif


BACKEND = Path(__file__).resolve().parents[1]
CLASSES = ("Premium", "Well-Milled", "Poor-Quality-Rice-Mix")
EXTENSIONS = {".heic", ".jpg", ".jpeg", ".png"}
# Collection target: 25-30 valid unique images per independent batch, the range in
# ml/image_preprocessing.TARGET_IMAGES_PER_BATCH. Advisory, not a hard CNN
# requirement; staging still never keeps more than TARGET_MAX images of one batch.
TARGET_MIN, TARGET_MAX = 25, 30
QUALITY = 95
pillow_heif.register_heif_opener()


def natural_key(value):
    """Tagged tokens avoid comparing integers with strings on unusual filenames."""
    return tuple((0, int(s)) if s.isdigit() else (1, s.casefold())
                 for s in re.split(r"(\d+)", str(value)))


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inspect_image(path):
    """Fully decode without resizing; compare orientation-corrected RGB pixels."""
    if path.stat().st_size == 0:
        raise ValueError("zero-byte file")
    with warnings.catch_warnings():
        warnings.simplefilter("error", Image.DecompressionBombWarning)
        with Image.open(path) as source:
            source.verify()
        with Image.open(path) as source:
            if source.format not in {"JPEG", "PNG", "HEIF", "HEIC"}:
                raise ValueError(f"unsupported actual image format: {source.format}")
            if getattr(source, "n_frames", 1) != 1:
                raise ValueError("multiple frames: refusing to discard frames")
            with ImageOps.exif_transpose(source).convert("RGB") as rgb:
                rgb.load()
                if rgb.width <= 0 or rgb.height <= 0:
                    raise ValueError("non-positive dimensions")
                digest = hashlib.sha256(str(rgb.size).encode("ascii"))
                digest.update(rgb.tobytes())
                return {"format": source.format, "stored_size": list(source.size),
                        "size": list(rgb.size), "pixel_sha256": digest.hexdigest()}


def audit_dataset(args):
    """Inventory all files; no output directories/files are created here."""
    source = args.source.resolve()
    if not source.is_dir():
        raise ValueError(f"Source dataset missing: {source}")
    supplied = (args.supplement_dir, args.supplement_class, args.supplement_batch)
    if any(supplied) and not all(supplied):
        raise ValueError("Supply all three --supplement-* arguments together")
    if args.supplement_batch and (Path(args.supplement_batch).name != args.supplement_batch
                                  or args.supplement_batch in {".", ".."}):
        raise ValueError("Supplement batch must be a single existing folder name")
    supplement = args.supplement_dir.resolve() if args.supplement_dir else None
    if supplement and (not supplement.is_dir() or supplement.is_relative_to(source)):
        raise ValueError("Supplement must be a separate existing source directory")
    target = source / (args.supplement_class or "") / (args.supplement_batch or "")
    if supplement and (not target.is_dir() or any(target.iterdir())):
        raise ValueError("Supplement target must be an existing, entirely empty batch")

    batches, records, outside, structural = [], [], [], []
    for entry in source.iterdir():
        if entry.is_dir() and entry.name not in CLASSES:
            structural.append(f"Unexpected class directory: {entry}")
    for path in source.rglob("*"):
        if path.is_symlink() or path.is_junction():
            structural.append(f"Link/junction must be reviewed: {path}")
        if path.is_file():
            relative = path.relative_to(source)
            if len(relative.parts) < 3 or relative.parts[0] not in CLASSES:
                outside.append(str(relative))
                if path.suffix.lower() in EXTENSIONS:
                    structural.append(f"Image outside a recognized batch: {path}")
    for class_name in CLASSES:
        class_dir = source / class_name
        if not class_dir.is_dir():
            structural.append(f"Missing class folder: {class_name}")
            continue
        for batch_dir in sorted((p for p in class_dir.iterdir() if p.is_dir()), key=natural_key):
            files = sorted((p for p in batch_dir.rglob("*") if p.is_file()), key=natural_key)
            is_supplement = supplement and batch_dir == target
            if is_supplement:
                if any(p.is_dir() or p.is_symlink() for p in supplement.iterdir()):
                    raise ValueError("Supplement must contain files directly, without directories/links")
                files = sorted(supplement.iterdir(), key=natural_key)
            counts = Counter()
            for path in files:
                extension = path.suffix.lower()
                counts[extension.lstrip(".") if extension in EXTENSIONS else "other"] += 1
                item = {"class": class_name, "batch": batch_dir.name,
                        "source_path": str(path), "source_filename": path.name,
                        "relative_filename": path.relative_to(supplement if is_supplement else batch_dir).as_posix(),
                        "extension": extension, "bytes": path.stat().st_size,
                        "file_sha256": sha256(path), "valid": False}
                try:
                    if extension not in EXTENSIONS:
                        raise ValueError("unsupported file type")
                    item.update(inspect_image(path))
                    item["valid"] = True
                except Exception as error:
                    item["error"] = f"{type(error).__name__}: {error}"
                records.append(item)
            batches.append({"class": class_name, "batch": batch_dir.name, "counts": dict(counts)})

    relationships = {}
    for name, key in (("exact_file_duplicates", "file_sha256"),
                      ("exact_pixel_duplicates", "pixel_sha256"),
                      ("duplicate_filenames", "source_filename")):
        groups = defaultdict(list)
        for item in records:
            if key in item:
                groups[item[key].casefold()].append(item)
        relationships[name] = [[r["source_path"] for r in group]
                               for group in groups.values() if len(group) > 1]
        if key != "source_filename":
            for group in groups.values():
                if len({(r["class"], r["batch"]) for r in group if r["valid"]}) > 1:
                    structural.append("Exact duplicate crosses groups: " + ", ".join(r["source_path"] for r in group))
    collisions = defaultdict(list)
    for item in records:
        key = (item["class"], item["batch"], str(Path(item["relative_filename"]).with_suffix(".jpg")).casefold())
        collisions[key].append(item["source_path"])
    return {"batches": batches, "records": records, "files_outside_batches": outside,
            "structural_problems": sorted(set(structural)),
            "destination_collisions": [v for v in collisions.values() if len(v) > 1], **relationships}


def batch_status(count):
    """0 EMPTY, 1-24 UNDER TARGET, 25-30 READY, over 30 OVER TARGET. Advisory only."""
    if count == 0:
        return "EMPTY"
    if count < TARGET_MIN:
        return "UNDER TARGET"
    return "READY" if count <= TARGET_MAX else "OVER TARGET"


def evenly_spaced(items):
    """Include both endpoints; integer nearest-index rounding is reproducible."""
    if len(items) <= TARGET_MAX:
        return items
    last, intervals = len(items) - 1, TARGET_MAX - 1
    indices = [(2 * i * last + intervals) // (2 * intervals) for i in range(TARGET_MAX)]
    assert len(set(indices)) == TARGET_MAX
    return [items[i] for i in indices]


def preferred_copy(item):
    """Prefer an existing JPEG and the original filename over '(1)' copies."""
    return (item.get("format") != "JPEG",
            bool(re.search(r"\(\d+\)$", Path(item["source_filename"]).stem)),
            natural_key(item["relative_filename"]))


def exclusive_copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as src, destination.open("xb") as dst:
        shutil.copyfileobj(src, dst)
    if sha256(source) != sha256(destination):
        raise ValueError(f"Copy checksum mismatch: {destination}")


def write_jpeg(item, destination):
    path = Path(item["source_path"])
    if item["format"] == "JPEG" and item["extension"] in {".jpg", ".jpeg"}:
        exclusive_copy(path, destination)
        method = "JPEG_COPIED"
    else:
        with Image.open(path) as source:
            with ImageOps.exif_transpose(source).convert("RGB") as rgb:
                # No EXIF orientation tag: pixels have already been transposed.
                with destination.open("xb") as stream:
                    rgb.save(stream, format="JPEG", quality=QUALITY,
                             icc_profile=rgb.info.get("icc_profile"))
        method = "HEIC_CONVERTED" if item["extension"] == ".heic" else "PNG_CONVERTED"
    validation = inspect_image(destination)
    if validation["format"] != "JPEG" or validation["size"] != item["size"]:
        raise ValueError(f"Output format/dimensions changed unexpectedly: {destination}")
    return method


def prepare(args, audit):
    data = BACKEND / "data"
    staged, excluded = data / "dataset_converted", data / "dataset_excluded"
    manifest = data / "dataset_conversion_manifest.csv"
    batch_csv = data / "dataset_batch_summary.csv"
    summary_file = data / "dataset_conversion_summary.json"
    outputs = (staged, excluded, manifest, batch_csv, summary_file)
    if audit["structural_problems"]:
        raise ValueError("Unsafe source structure: " + "; ".join(audit["structural_problems"]))
    # Identical basenames do not prove that a HEIC and a JPEG depict the same
    # photograph. Refuse ambiguous names before staging anything, rather than
    # silently discarding different pixels or failing halfway through a copy.
    records_by_path = {item["source_path"]: item for item in audit["records"]}
    for collision in audit.get("destination_collisions", []):
        valid = [records_by_path[path] for path in collision if records_by_path[path]["valid"]]
        if len({item["pixel_sha256"] for item in valid}) > 1:
            raise ValueError("Different images would share an output JPEG name: " + ", ".join(collision))
    if any(p.exists() for p in outputs):
        raise ValueError("Existing staging/report output: refusing overwrite; preserve it before a new run")
    for source_dir in (args.source.resolve(), args.supplement_dir.resolve() if args.supplement_dir else None):
        if source_dir and any(source_dir.is_relative_to(p) or p.is_relative_to(source_dir) for p in (staged, excluded)):
            raise ValueError("Source and output directories must not overlap")
    for item in audit["records"]:
        if sha256(Path(item["source_path"])) != item["file_sha256"]:
            raise ValueError(f"Source changed after audit: {item['source_path']}")

    staged.mkdir()
    excluded.mkdir()
    rows, summaries, conversions = [], [], Counter()
    with tempfile.TemporaryDirectory(prefix="rice_conversion_", dir=data) as temporary:
        work = Path(temporary)
        for batch in audit["batches"]:
            class_name, batch_name = batch["class"], batch["batch"]
            relative_batch = Path(class_name) / batch_name
            (staged / relative_batch).mkdir(parents=True)
            (excluded / relative_batch).mkdir(parents=True)
            members = [r for r in audit["records"] if r["class"] == class_name and r["batch"] == batch_name]
            source_valid = sum(r["valid"] for r in members)
            files_seen, pixels_seen = {}, {}
            candidates, batch_rows = [], []
            for number, item in enumerate(sorted(members, key=preferred_copy)):
                row = {"class": class_name, "batch": batch_name,
                       "source_filename": item["relative_filename"], "output_filename": "",
                       "status": "", "reason": "", "source_path": item["source_path"],
                       "source_sha256": item["file_sha256"], "output_sha256": ""}
                batch_rows.append(row)
                duplicate = None
                if not item["valid"]:
                    row.update(status="INVALID_IMAGE", reason=item["error"])
                else:
                    duplicate = (files_seen.get(item["file_sha256"]) or
                                 pixels_seen.get(item["pixel_sha256"]))
                    if duplicate:
                        row.update(status="EXCLUDED_DUPLICATE",
                                   reason=f"Same file or decoded pixels as {duplicate['relative_filename']}")
                    else:
                        candidate = work / f"{class_name}_{batch_name}_{number}.jpg"
                        try:
                            method = write_jpeg(item, candidate)
                            conversions[method] += 1
                            candidates.append((item, row, candidate, method))
                            files_seen[item["file_sha256"]] = item
                            pixels_seen[item["pixel_sha256"]] = item
                        except Exception as error:
                            row.update(status="FAILED_CONVERSION", reason=f"{type(error).__name__}: {error}")
            candidates.sort(key=lambda value: natural_key(value[0]["relative_filename"]))
            chosen = {value[0]["source_path"] for value in evenly_spaced(candidates)}
            for item, row, candidate, method in candidates:
                if item["source_path"] in chosen:
                    output = Path(item["relative_filename"]).with_suffix(".jpg")
                    exclusive_copy(candidate, staged / relative_batch / output)
                    row.update(output_filename=output.as_posix(), status="SELECTED",
                               reason=f"{method}; natural order, evenly spaced if >{TARGET_MAX}; quality={QUALITY} for conversion",
                               output_sha256=sha256(staged / relative_batch / output))
                else:
                    row.update(status="EXCLUDED_OVER_30", reason=f"Outside deterministic {TARGET_MAX}-image selection")
            for row in batch_rows:
                if row["status"] != "SELECTED":
                    output = Path(row["source_filename"])
                    exclusive_copy(Path(row["source_path"]), excluded / relative_batch / output)
                    row["output_filename"] = output.as_posix()
                    row["output_sha256"] = sha256(excluded / relative_batch / output)
            selected = sum(r["status"] == "SELECTED" for r in batch_rows)
            failed = sum(r["status"] in {"INVALID_IMAGE", "FAILED_CONVERSION"} for r in batch_rows)
            excluded_count = sum(r["status"] in {"EXCLUDED_DUPLICATE", "EXCLUDED_OVER_30"} for r in batch_rows)
            # Judged on valid unique images before the trim: a trimmed batch reads
            # OVER TARGET, and valid_before_trim vs selected shows what was kept.
            status = batch_status(len(candidates))
            summaries.append({"class": class_name, "batch": batch_name, "source_valid": source_valid,
                              "valid_before_trim": len(candidates), "selected": selected,
                              "excluded": excluded_count, "failed": failed, "status": status})
            rows.extend(sorted(batch_rows, key=lambda row: natural_key(row["source_filename"])))

    # Reopen every final training file; check bytes, dimensions, grouping and duplicates.
    pixels = set()
    for batch in summaries:
        folder = staged / batch["class"] / batch["batch"]
        files = [p for p in folder.rglob("*") if p.is_file()]
        if len(files) != batch["selected"] or len(files) > TARGET_MAX:
            raise ValueError(f"Final batch count violation: {folder}")
        for path in files:
            image = inspect_image(path)
            if path.suffix != ".jpg" or image["format"] != "JPEG":
                raise ValueError(f"Non-JPEG staged output: {path}")
            if image["pixel_sha256"] in pixels:
                raise ValueError(f"Duplicate final training image: {path}")
            pixels.add(image["pixel_sha256"])
    for item in audit["records"]:
        if sha256(Path(item["source_path"])) != item["file_sha256"]:
            raise ValueError(f"Original source changed: {item['source_path']}")
    with manifest.open("x", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]) if rows else
                                ["class", "batch", "source_filename", "output_filename", "status", "reason"])
        writer.writeheader()
        writer.writerows(rows)
    with batch_csv.open("x", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(summaries[0]))
        writer.writeheader()
        writer.writerows(summaries)
    result = {"target": [TARGET_MIN, TARGET_MAX], "quality": QUALITY, "selection": "natural order; integer nearest evenly spaced indices including endpoints",
              "source": str(args.source.resolve()), "supplement": str(args.supplement_dir.resolve()) if args.supplement_dir else None,
              "conversions": dict(conversions), "batches": summaries,
              "statuses": dict(Counter(r["status"] for r in rows)),
              "selected_jpg_validated": len(pixels), "originals_unchanged": True,
              "promoted": False, "training_performed": False, "audit": audit}
    with summary_file.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
    return {key: value for key, value in result.items() if key != "audit"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=BACKEND / "data" / "dataset")
    parser.add_argument("--supplement-dir", type=Path)
    parser.add_argument("--supplement-class", choices=CLASSES)
    parser.add_argument("--supplement-batch")
    parser.add_argument("--prepare", action="store_true", help="Create fresh staging after printing the audit; never promote")
    args = parser.parse_args()
    try:
        audit = audit_dataset(args)
        print(json.dumps({"phase": "READ_ONLY_AUDIT", **audit}, indent=2), flush=True)
        if args.prepare:
            print(json.dumps({"phase": "PREPARED", **prepare(args, audit)}, indent=2))
    except Exception as error:
        parser.exit(1, f"Preparation stopped safely: {type(error).__name__}: {error}\n"
                    "No originals were deleted; existing outputs are never overwritten.\n")


if __name__ == "__main__":
    main()
