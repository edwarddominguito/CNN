"""Convert every dataset HEIC/HEIF to JPEG, retaining verified original backups.

From backend: python -m scripts.convert_dataset_heic [--apply]
Without --apply, only the conversion plan is printed; no files are written.
"""

import argparse
import hashlib
import json
import os
import shutil
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from PIL import Image

from app.paths import BACKEND_DIR, DATASET_DIR
from ml.image_preprocessing import CLASS_NAMES, HEIF_EXTENSIONS, IMAGE_EXTENSIONS, load_rgb_image


DEFAULT_BACKUP_ROOT = BACKEND_DIR / "dataset_backups"
PHOTO_EXTENSIONS = IMAGE_EXTENSIONS | {".bmp", ".gif", ".tif", ".tiff", ".avif"}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def reject_links(path):
    """Check before resolve(), which would hide a linked ancestor."""
    absolute = Path(path).absolute()
    for entry in (absolute, *absolute.parents):
        if entry.is_symlink() or entry.is_junction():
            raise ValueError(f"Link/junction must be reviewed before conversion: {entry}")


def checked_child(root, relative):
    target = root / relative
    reject_links(target)
    if not target.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Path escapes its intended directory: {target}")
    return target


def plan_conversion(source):
    reject_links(source)
    source = Path(source).resolve()
    if not source.is_dir():
        raise ValueError(f"Dataset folder not found: {source}")
    files, candidates, image_count = {}, [], 0

    def walk_error(error):
        raise error

    for directory, folders, names in os.walk(source, followlinks=False, onerror=walk_error):
        current = Path(directory)
        for name in sorted(folders):
            folder = current / name
            reject_links(folder)
            if current == source and name not in CLASS_NAMES:
                raise ValueError(f"Unrecognized grade folder: {folder}")
        for name in sorted(names):
            path = current / name
            reject_links(path)
            relative = path.relative_to(source)
            key = relative.as_posix().casefold()
            if key in files:
                raise ValueError(f"Case-insensitive filename collision: {path}")
            files[key] = path
            if path.suffix.lower() in PHOTO_EXTENSIONS:
                if len(relative.parts) < 3 or relative.parts[0] not in CLASS_NAMES:
                    raise ValueError(f"Image outside a recognized grade/batch folder: {path}")
                image_count += 1
            if path.suffix.lower() in HEIF_EXTENSIONS:
                candidates.append(relative)

    records, outputs = [], set()
    for relative in sorted(candidates):
        output = relative.with_suffix(".jpg")
        key = output.as_posix().casefold()
        if key in files or key in outputs:
            raise ValueError(f"JPEG destination already exists or would collide: {source / output}")
        outputs.add(key)
        records.append({"source_relative": relative.as_posix(), "output_relative": output.as_posix()})
    return {"source": str(source), "image_count": image_count,
            "conversion_count": len(records), "files": records}


def copy_verified(source, target, expected_hash):
    """Exclusive creation avoids overwriting a file that appeared after planning."""
    target.parent.mkdir(parents=True, exist_ok=True)
    reject_links(target)
    created = False
    try:
        with source.open("rb") as src, target.open("xb") as dst:
            created = True
            shutil.copyfileobj(src, dst)
        if sha256(target) != expected_hash:
            raise ValueError(f"Copy checksum mismatch: {target}")
    except BaseException:
        if created:
            target.unlink(missing_ok=True)
        raise


def write_manifest(path, manifest):
    pending = path.with_suffix(".pending.json")
    with pending.open("w", encoding="utf-8") as stream:
        json.dump(manifest, stream, indent=2, allow_nan=False)
        stream.write("\n")
    pending.replace(path)


def encode_jpeg(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    with load_rgb_image(source) as rgb:
        size = rgb.size
        with target.open("xb") as stream:
            # Pixels already carry the phone orientation; do not copy its EXIF tag.
            rgb.save(stream, format="JPEG", quality=95, subsampling=0,
                     icc_profile=rgb.info.get("icc_profile"))
    with Image.open(target) as output:
        output.load()
        if output.format != "JPEG" or output.mode != "RGB" or output.size != size:
            raise ValueError(f"Invalid converted JPEG: {target}")
    return list(size)


def apply_conversion(source, backup_root=None):
    plan = plan_conversion(source)
    source = Path(plan["source"])
    if not plan["conversion_count"]:
        return {"status": "no_changes", "converted": 0, "image_count": plan["image_count"],
                "backup": None}
    backup_root = Path(backup_root) if backup_root is not None else DEFAULT_BACKUP_ROOT
    reject_links(backup_root)
    backup_root = backup_root.resolve()
    if source.is_relative_to(backup_root) or backup_root.is_relative_to(source):
        raise ValueError("Dataset and backup directories must not overlap.")
    run_name = datetime.now(timezone.utc).strftime("heic_to_jpeg_%Y%m%dT%H%M%SZ_") + uuid4().hex[:10]
    run_dir = checked_child(backup_root, run_name)
    run_dir.mkdir(parents=True, exist_ok=False)
    manifest_path = run_dir / "manifest.json"
    manifest = {"status": "staging", "source": str(source), "backup": str(run_dir),
                "quality": 95, "subsampling": 0, "image_count_before": plan["image_count"],
                "files": []}
    promoted = []

    try:
        # Every JPEG is encoded and fully decoded before active data is changed.
        for planned in plan["files"]:
            original = checked_child(source, planned["source_relative"])
            staged = checked_child(run_dir / "staged", planned["output_relative"])
            source_hash = sha256(original)
            size = encode_jpeg(original, staged)
            if sha256(original) != source_hash:
                raise ValueError(f"Original changed during conversion: {original}")
            manifest["files"].append({**planned, "source_sha256": source_hash,
                                      "output_sha256": sha256(staged), "size": size,
                                      "source_bytes": original.stat().st_size,
                                      "output_bytes": staged.stat().st_size})

        # Keep every original byte, not just the JPEG, outside the active dataset.
        for item in manifest["files"]:
            original = checked_child(source, item["source_relative"])
            backup = checked_child(run_dir / "originals", item["source_relative"])
            copy_verified(original, backup, item["source_sha256"])
        manifest["status"] = "originals_backed_up"
        write_manifest(manifest_path, manifest)

        # Re-plan immediately before promotion to catch newly introduced collisions.
        if plan_conversion(source) != plan:
            raise ValueError("Dataset contents changed after planning; conversion was stopped.")
        for item in manifest["files"]:
            original = checked_child(source, item["source_relative"])
            if sha256(original) != item["source_sha256"]:
                raise ValueError(f"Original changed after backup: {original}")
            active = checked_child(source, item["output_relative"])
            staged = checked_child(run_dir / "staged", item["output_relative"])
            copy_verified(staged, active, item["output_sha256"])
            promoted.append(item)

        # This journal, with all source/output hashes, exists before any unlink.
        manifest["status"] = "removing_backed_up_originals"
        write_manifest(manifest_path, manifest)
        for item in manifest["files"]:
            original = checked_child(source, item["source_relative"])
            active = checked_child(source, item["output_relative"])
            backup = checked_child(run_dir / "originals", item["source_relative"])
            if (sha256(original) != item["source_sha256"] or
                    sha256(backup) != item["source_sha256"] or
                    sha256(active) != item["output_sha256"]):
                raise ValueError(f"Checksum changed before removing backed-up original: {original}")
            original.unlink()

        after = plan_conversion(source)
        if after["conversion_count"] or after["image_count"] != plan["image_count"]:
            raise ValueError("Converted dataset counts do not match the original inventory.")
        manifest["status"] = "completed"
        manifest["image_count_after"] = after["image_count"]
        write_manifest(manifest_path, manifest)
    except BaseException as error:
        rollback_errors = []
        # Restore each removed original before removing its promoted JPEG.
        for item in reversed(promoted):
            try:
                original = checked_child(source, item["source_relative"])
                active = checked_child(source, item["output_relative"])
                backup = checked_child(run_dir / "originals", item["source_relative"])
                if not original.exists():
                    copy_verified(backup, original, item["source_sha256"])
                if sha256(original) != item["source_sha256"]:
                    raise ValueError(f"Original changed; promoted JPEG retained: {original}")
                if active.exists():
                    if sha256(active) != item["output_sha256"]:
                        raise ValueError(f"JPEG changed; refusing to remove it: {active}")
                    active.unlink()
            except (OSError, ValueError) as rollback_error:
                rollback_errors.append(str(rollback_error))
        manifest.update(status="failed", error=f"{type(error).__name__}: {error}",
                        rollback_errors=rollback_errors)
        try:
            write_manifest(manifest_path, manifest)
        except OSError:
            pass
        detail = "; ".join(rollback_errors) or "Active conversions were rolled back."
        raise RuntimeError(f"Conversion stopped safely. Originals/backups retained at {run_dir}. "
                           f"{type(error).__name__}: {error}. {detail}") from error

    return {"status": "completed", "converted": len(manifest["files"]),
            "image_count": manifest["image_count_after"], "backup": str(run_dir),
            "manifest": str(manifest_path)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DATASET_DIR)
    parser.add_argument("--backup-root", type=Path, default=DEFAULT_BACKUP_ROOT)
    parser.add_argument("--apply", action="store_true", help="Back up and replace HEIC/HEIF with verified JPEGs")
    args = parser.parse_args()
    try:
        if args.apply:
            result = apply_conversion(args.source, args.backup_root)
        else:
            plan = plan_conversion(args.source)
            result = {key: value for key, value in plan.items() if key != "files"}
            result["status"] = "read_only_plan"
            result["conversions_per_batch"] = dict(Counter(
                "/".join(Path(item["source_relative"]).parts[:2]) for item in plan["files"]
            ))
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, RuntimeError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
