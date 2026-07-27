#!/usr/bin/env python3

import argparse
import math
import re
from pathlib import Path
from typing import Optional

import pandas as pd


# ============================================================
# 1. 解析实验目录名称
# ============================================================

ADDITIONAL_PATTERN = re.compile(
    r"^additional_only_rate_(?P<rate>\d+)"
    r"_layer_(?P<layer>\d+)"
    r"_strat_(?P<strat>.+)$"
)

COMPRESSION_PATTERN = re.compile(
    r"^compression_only_ratio_(?P<ratio>\d+(?:\.\d+)?)$"
)

BOTH_PATTERN = re.compile(
    r"^both_rate_(?P<rate>\d+)"
    r"_layer_(?P<layer>\d+)"
    r"_strat_(?P<strat>.+)"
    r"_ratio_(?P<ratio>\d+(?:\.\d+)?)$"
)


def parse_experiment_name(dirname: str) -> Optional[dict]:
    """
    解析三种实验目录名称。

    返回字段：
        feature_type:
            additional_only
            compression_only
            both

        rate:
            LLM 裁剪 rate，不适用时为 NaN

        layer:
            LLM 裁剪 layer，不适用时为 NaN

        strat:
            LLM 裁剪策略，不适用时为空

        ratio:
            ViT 裁剪比例，不适用时为 NaN
    """

    match = ADDITIONAL_PATTERN.fullmatch(dirname)
    if match:
        return {
            "feature_type": "additional_only",
            "rate": int(match.group("rate")),
            "layer": int(match.group("layer")),
            "strat": match.group("strat"),
            "ratio": math.nan,
        }

    match = COMPRESSION_PATTERN.fullmatch(dirname)
    if match:
        return {
            "feature_type": "compression_only",
            "rate": math.nan,
            "layer": math.nan,
            "strat": "",
            "ratio": float(match.group("ratio")),
        }

    match = BOTH_PATTERN.fullmatch(dirname)
    if match:
        return {
            "feature_type": "both",
            "rate": int(match.group("rate")),
            "layer": int(match.group("layer")),
            "strat": match.group("strat"),
            "ratio": float(match.group("ratio")),
        }

    return None


# ============================================================
# 2. 找到第一个时间戳目录中的 summary 文件
# ============================================================

def find_first_summary_file(experiment_dir: Path) -> tuple[
    Optional[str],
    Optional[Path],
]:
    """
    在实验目录中查找第一个时间戳目录。

    例如：
        both_rate_4_layer_15_strat_pp_nc_ratio_0.3/
            20260725_183246/
                summary/
                    summary_20260725_183246.txt

    如果有多个时间戳目录，按目录名排序后取第一个。
    """

    timestamp_dirs = sorted(
        path
        for path in experiment_dir.iterdir()
        if path.is_dir()
    )

    if not timestamp_dirs:
        return None, None

    first_timestamp_dir = timestamp_dirs[0]
    summary_dir = first_timestamp_dir / "summary"

    if not summary_dir.is_dir():
        return first_timestamp_dir.name, None

    summary_files = sorted(summary_dir.glob("summary_*.txt"))

    if not summary_files:
        # 如果文件没有以 summary_ 开头，也尝试使用任意 txt
        summary_files = sorted(summary_dir.glob("*.txt"))

    if not summary_files:
        return first_timestamp_dir.name, None

    return first_timestamp_dir.name, summary_files[0]


# ============================================================
# 3. 从 summary txt 中提取 accuracy
# ============================================================

def extract_accuracy(summary_file: Path) -> float:
    """
    优先从 CSV 格式中提取：

        textvqa,40b285,accuracy,gen,76.97

    如果失败，再从 raw 格式中提取：

        textvqa: {'accuracy': 76.9699999999999}
    """

    content = summary_file.read_text(
        encoding="utf-8",
        errors="replace",
    )

    # CSV 格式，约束 dataset=textvqa，metric=accuracy
    csv_pattern = re.compile(
        r"^textvqa\s*,\s*[^,\r\n]+\s*,\s*accuracy\s*,"
        r"\s*[^,\r\n]+\s*,\s*"
        r"(?P<accuracy>[+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*$",
        flags=re.MULTILINE | re.IGNORECASE,
    )

    match = csv_pattern.search(content)
    if match:
        return float(match.group("accuracy"))

    # raw 格式
    raw_pattern = re.compile(
        r"textvqa\s*:\s*\{[^}]*"
        r"['\"]accuracy['\"]\s*:\s*"
        r"(?P<accuracy>[+-]?(?:\d+(?:\.\d*)?|\.\d+))",
        flags=re.IGNORECASE,
    )

    match = raw_pattern.search(content)
    if match:
        return float(match.group("accuracy"))

    # tabulate / markdown / tab 分隔格式兜底
    table_pattern = re.compile(
        r"^textvqa\s+"
        r"\S+\s+"
        r"accuracy\s+"
        r"\S+\s+"
        r"(?P<accuracy>[+-]?(?:\d+(?:\.\d*)?|\.\d+))\s*$",
        flags=re.MULTILINE | re.IGNORECASE,
    )

    match = table_pattern.search(content)
    if match:
        return float(match.group("accuracy"))

    return math.nan


# ============================================================
# 4. 扫描根目录
# ============================================================

def scan_experiments(root: Path) -> pd.DataFrame:
    records = []

    for experiment_dir in sorted(root.iterdir()):
        if not experiment_dir.is_dir():
            continue

        hyperparams = parse_experiment_name(experiment_dir.name)

        if hyperparams is None:
            print(
                f"[SKIP] 无法识别实验目录名称："
                f"{experiment_dir.name}"
            )
            continue

        timestamp, summary_file = find_first_summary_file(
            experiment_dir
        )

        if summary_file is None:
            accuracy = math.nan
            print(
                f"[WARN] 未找到 summary 文件："
                f"{experiment_dir.name}"
            )
        else:
            accuracy = extract_accuracy(summary_file)

            if pd.isna(accuracy):
                print(
                    f"[WARN] 未提取到 accuracy："
                    f"{summary_file}"
                )

        record = {
            "experiment_name": experiment_dir.name,
            **hyperparams,
            "timestamp": timestamp or "",
            "accuracy": accuracy,
            "summary_file": (
                str(summary_file)
                if summary_file is not None
                else ""
            ),
        }

        records.append(record)

        accuracy_text = (
            "NaN"
            if pd.isna(accuracy)
            else f"{accuracy:.6f}"
        )

        print(
            f"[OK] "
            f"type={record['feature_type']:<16} "
            f"rate={str(record['rate']):<6} "
            f"layer={str(record['layer']):<6} "
            f"strat={record['strat']:<15} "
            f"ratio={str(record['ratio']):<6} "
            f"accuracy={accuracy_text}"
        )

    columns = [
        "experiment_name",
        "feature_type",
        "rate",
        "layer",
        "strat",
        "ratio",
        "timestamp",
        "accuracy",
        "summary_file",
    ]

    return pd.DataFrame(records, columns=columns)


# ============================================================
# 5. 构造数据透视表
# ============================================================

def build_pivot_table(df: pd.DataFrame) -> pd.DataFrame:
    """
    行索引：
        feature_type, strat, layer, rate

    列索引：
        ratio

    单元格：
        accuracy 平均值

    NaN accuracy 会被 mean 自动忽略。
    """

    pivot_source = df.copy()

    # 为了让“不适用”的超参数也能出现在数据透视表中，
    # 将空值替换为可读标识。
    pivot_source["strat"] = (
        pivot_source["strat"]
        .replace("", "N/A")
        .fillna("N/A")
    )

    pivot_source["layer_display"] = (
        pivot_source["layer"]
        .apply(
            lambda value:
            "N/A" if pd.isna(value) else int(value)
        )
    )

    pivot_source["rate_display"] = (
        pivot_source["rate"]
        .apply(
            lambda value:
            "N/A" if pd.isna(value) else int(value)
        )
    )

    pivot_source["ratio_display"] = (
        pivot_source["ratio"]
        .apply(
            lambda value:
            "N/A" if pd.isna(value) else float(value)
        )
    )

    pivot = pd.pivot_table(
        pivot_source,
        values="accuracy",
        index=[
            "feature_type",
            "strat",
            "layer_display",
            "rate_display",
        ],
        columns="ratio_display",
        aggfunc="mean",
        dropna=False,
    )

    pivot.index.names = [
        "feature_type",
        "strat",
        "layer",
        "rate",
    ]

    pivot.columns.name = "ratio"

    return pivot


# ============================================================
# 6. 额外汇总
# ============================================================

def build_strat_mean(df: pd.DataFrame) -> pd.DataFrame:
    """
    对每个 strat 求总体平均。

    compression_only 没有 strat，因此不放进该表。
    NaN accuracy 自动跳过。
    """

    strat_df = df[
        df["strat"].notna()
        & df["strat"].ne("")
    ]

    return (
        strat_df
        .groupby("strat", as_index=False)["accuracy"]
        .mean()
        .rename(
            columns={
                "accuracy": "mean_accuracy"
            }
        )
        .sort_values(
            "mean_accuracy",
            ascending=False,
            na_position="last",
        )
    )


def build_feature_mean(df: pd.DataFrame) -> pd.DataFrame:
    """
    对 additional_only、compression_only、both
    三种实验类型分别求平均。
    """

    return (
        df
        .groupby(
            "feature_type",
            as_index=False,
        )["accuracy"]
        .mean()
        .rename(
            columns={
                "accuracy": "mean_accuracy"
            }
        )
        .sort_values(
            "mean_accuracy",
            ascending=False,
            na_position="last",
        )
    )


# ============================================================
# 7. 输出 CSV 和 Excel
# ============================================================

def save_results(
    df: pd.DataFrame,
    pivot: pd.DataFrame,
    strat_mean: pd.DataFrame,
    feature_mean: pd.DataFrame,
    output_prefix: Path,
) -> None:

    output_prefix.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    raw_csv = output_prefix.with_name(
        output_prefix.name + "_all_results.csv"
    )

    pivot_csv = output_prefix.with_name(
        output_prefix.name + "_pivot.csv"
    )

    excel_file = output_prefix.with_suffix(".xlsx")

    df.to_csv(
        raw_csv,
        index=False,
        encoding="utf-8-sig",
    )

    pivot.to_csv(
        pivot_csv,
        encoding="utf-8-sig",
    )

    with pd.ExcelWriter(
        excel_file,
        engine="openpyxl",
    ) as writer:

        df.to_excel(
            writer,
            sheet_name="all_results",
            index=False,
        )

        pivot.to_excel(
            writer,
            sheet_name="pivot",
        )

        strat_mean.to_excel(
            writer,
            sheet_name="strat_mean",
            index=False,
        )

        feature_mean.to_excel(
            writer,
            sheet_name="feature_mean",
            index=False,
        )

        # 每个实验类型单独生成一张明细表
        for feature_type, group in df.groupby(
            "feature_type"
        ):
            group.to_excel(
                writer,
                sheet_name=feature_type[:31],
                index=False,
            )

    print("\n输出文件：")
    print(f"  明细 CSV：{raw_csv}")
    print(f"  透视表 CSV：{pivot_csv}")
    print(f"  Excel：{excel_file}")


# ============================================================
# 8. 主函数
# ============================================================

def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "扫描 LLM/VIT 裁剪超参数实验，"
            "提取 textvqa accuracy 并生成数据透视表。"
        )
    )

    parser.add_argument(
        "root",
        type=Path,
        help="实验根目录",
    )

    parser.add_argument(
        "--output-prefix",
        type=Path,
        default=Path("accuracy_summary"),
        help=(
            "输出文件前缀，默认 accuracy_summary。"
            "例如 ./result/accuracy_summary"
        ),
    )

    args = parser.parse_args()

    root = args.root.expanduser().resolve()

    if not root.is_dir():
        raise NotADirectoryError(
            f"实验根目录不存在或不是目录：{root}"
        )

    print(f"扫描根目录：{root}\n")

    df = scan_experiments(root)

    if df.empty:
        print("\n没有找到符合命名规则的实验目录。")
        return

    pivot = build_pivot_table(df)
    strat_mean = build_strat_mean(df)
    feature_mean = build_feature_mean(df)

    print("\n================ 全部实验结果 ================\n")
    print(
        df[
            [
                "feature_type",
                "rate",
                "layer",
                "strat",
                "ratio",
                "accuracy",
            ]
        ].to_string(index=False)
    )

    print("\n================ 数据透视表 ================\n")
    print(pivot.to_string())

    print("\n================ strat 总体平均 ================\n")
    print(strat_mean.to_string(index=False))

    print("\n================ 特性类型平均 ================\n")
    print(feature_mean.to_string(index=False))

    save_results(
        df=df,
        pivot=pivot,
        strat_mean=strat_mean,
        feature_mean=feature_mean,
        output_prefix=args.output_prefix,
    )


if __name__ == "__main__":
    main()