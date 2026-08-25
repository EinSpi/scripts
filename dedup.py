import argparse
import hashlib
import json
import os
from pathlib import Path


def calc_md5(file_path: str, chunk_size: int = 1024 * 1024) -> str:
    """
    流式计算文件 MD5，避免大图片一次性读入内存。
    """
    md5 = hashlib.md5()

    with open(file_path, "rb") as f:
        while chunk := f.read(chunk_size):
            md5.update(chunk)

    return md5.hexdigest()


def resolve_image_path(image_path: str, jsonl_dir: str) -> str:
    """
    支持：
      /data/xxx.jpg
      relative/path.jpg
      file:///data/xxx.jpg
    """
    if image_path.startswith("file://"):
        image_path = image_path[len("file://"):]

    if not os.path.isabs(image_path):
        image_path = os.path.join(jsonl_dir, image_path)

    return os.path.abspath(image_path)


def dedup_mm_custom_dataset(
    input_jsonl: str,
    output_jsonl: str,
    duplicate_jsonl: str | None = None,
):
    jsonl_dir = os.path.dirname(os.path.abspath(input_jsonl))

    # md5 -> 首次使用该图片的 testcase 信息
    seen_md5 = {}

    kept_samples = []
    removed_samples = []

    total_images = 0

    with open(input_jsonl, "r", encoding="utf-8") as f:
        for line_idx, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue

            sample = json.loads(line)

            # ---------------------------------------------------------
            # 1. 检查是不是 image 类型
            # ---------------------------------------------------------
            if sample.get("type") != "image":
                raise ValueError(
                    f"Line {line_idx}: type={sample.get('type')!r}, "
                    f"expected 'image'"
                )

            paths = sample.get("path")

            # ---------------------------------------------------------
            # 2. 每条 testcase 支持一张或两张图片
            # ---------------------------------------------------------
            if not isinstance(paths, list) or len(paths) not in (1, 2):
                raise ValueError(
                    f"Line {line_idx}: expected 1 or 2 images, "
                    f"but got path={paths!r}"
                )

            image_infos = []

            # ---------------------------------------------------------
            # 3. 计算图片 MD5
            # ---------------------------------------------------------
            for image_path in paths:
                real_path = resolve_image_path(image_path, jsonl_dir)

                if not os.path.isfile(real_path):
                    raise FileNotFoundError(
                        f"Line {line_idx}: image not found: {real_path}"
                    )

                md5 = calc_md5(real_path)

                image_infos.append(
                    {
                        "original_path": image_path,
                        "real_path": real_path,
                        "md5": md5,
                    }
                )

            total_images += len(image_infos)

            # ---------------------------------------------------------
            # 4. 同 testcase 内部图片本身就是重复的
            # ---------------------------------------------------------
            sample_md5s = [info["md5"] for info in image_infos]
            duplicate_md5s = sorted(
                {md5 for md5 in sample_md5s if sample_md5s.count(md5) > 1}
            )

            if duplicate_md5s:
                removed_samples.append(
                    {
                        "line": line_idx,
                        "reason": "duplicate_inside_sample",
                        "duplicate_md5": duplicate_md5s,
                        "sample": sample,
                    }
                )

                print(
                    f"[DROP] line={line_idx}: "
                    f"images inside sample have duplicate MD5 "
                    f"{', '.join(duplicate_md5s)}"
                )
                continue

            # ---------------------------------------------------------
            # 5. 检查是否与之前保留 testcase 中的图片重复
            # ---------------------------------------------------------
            conflicts = []

            for info in image_infos:
                if info["md5"] in seen_md5:
                    previous = seen_md5[info["md5"]]

                    conflicts.append(
                        {
                            "md5": info["md5"],
                            "current_image": info["original_path"],
                            "previous_line": previous["line"],
                            "previous_image": previous["image"],
                        }
                    )

            if conflicts:
                removed_samples.append(
                    {
                        "line": line_idx,
                        "reason": "duplicate_with_previous_sample",
                        "conflicts": conflicts,
                        "sample": sample,
                    }
                )

                print(f"[DROP] line={line_idx}")

                for c in conflicts:
                    print(
                        f"       md5={c['md5']}\n"
                        f"       current={c['current_image']}\n"
                        f"       duplicated with line "
                        f"{c['previous_line']}: "
                        f"{c['previous_image']}"
                    )

                continue

            # ---------------------------------------------------------
            # 6. 当前 testcase 图片均未出现，保留
            # ---------------------------------------------------------
            kept_samples.append(sample)

            for info in image_infos:
                seen_md5[info["md5"]] = {
                    "line": line_idx,
                    "image": info["original_path"],
                }

    # -------------------------------------------------------------
    # 写出去重后的 JSONL
    # -------------------------------------------------------------
    os.makedirs(
        os.path.dirname(os.path.abspath(output_jsonl)),
        exist_ok=True,
    )

    with open(output_jsonl, "w", encoding="utf-8") as f:
        for sample in kept_samples:
            f.write(json.dumps(sample, ensure_ascii=False) + "\n")

    # -------------------------------------------------------------
    # 可选：记录被删除 testcase
    # -------------------------------------------------------------
    if duplicate_jsonl:
        with open(duplicate_jsonl, "w", encoding="utf-8") as f:
            for item in removed_samples:
                f.write(json.dumps(item, ensure_ascii=False) + "\n")

    print()
    print("=" * 70)
    print("Dedup finished")
    print("=" * 70)
    print(f"Input samples     : {len(kept_samples) + len(removed_samples)}")
    print(f"Kept samples      : {len(kept_samples)}")
    print(f"Removed samples   : {len(removed_samples)}")
    print(f"Input images      : {total_images}")
    print(f"Output images     : {len(seen_md5)}")
    print(f"Unique MD5 count  : {len(seen_md5)}")
    print(f"Output            : {output_jsonl}")

    if duplicate_jsonl:
        print(f"Duplicate report  : {duplicate_jsonl}")

    # 理论上输出图片数和唯一 MD5 数必须完全一致
    assert len(seen_md5) == sum(len(sample["path"]) for sample in kept_samples)

    print()
    print(
        f"[PASS] All {len(seen_md5)} images "
        f"in output dataset have unique MD5."
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Deduplicate AISBench mm_custom_gen image dataset by MD5"
    )

    parser.add_argument(
        "input",
        help="Input mm_custom JSONL",
    )

    parser.add_argument(
        "output",
        help="Output deduplicated JSONL",
    )

    parser.add_argument(
        "--duplicate-output",
        default=None,
        help="Optional JSONL containing removed samples",
    )

    args = parser.parse_args()

    dedup_mm_custom_dataset(
        input_jsonl=args.input,
        output_jsonl=args.output,
        duplicate_jsonl=args.duplicate_output,
    )
