#!/usr/bin/env bash
set -Eeuo pipefail

: "${FEISHU_APP_ID:?Missing FEISHU_APP_ID secret}"
: "${FEISHU_APP_SECRET:?Missing FEISHU_APP_SECRET secret}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# The sync manifest is deliberately limited to one document for this MVP.
readarray -t DOC_FIELDS < <(python3 - <<'PY'
import yaml
with open("sync/docs.yaml", "r", encoding="utf-8") as f:
    config = yaml.safe_load(f) or {}
docs = config.get("docs", [])
if len(docs) != 1:
    raise SystemExit(f"MVP expects exactly one document; found {len(docs)}")
doc = docs[0]
url = str(doc["feishu_url"]).strip()
target = str(doc["target"]).strip()
weight = int(doc.get("weight", 10))
if not url.startswith("https://") or ".feishu.cn/" not in url:
    raise SystemExit("feishu_url must be an HTTPS Feishu URL")
if not target.startswith("content/docs/") or ".." in target.split("/"):
    raise SystemExit("target must stay inside content/docs/")
print(url)
print(target)
print(weight)
PY
)

DOC_URL="${DOC_FIELDS[0]}"
TARGET="${DOC_FIELDS[1]}"
WEIGHT="${DOC_FIELDS[2]}"
TARGET_DIR="$(dirname "$TARGET")"
mkdir -p "$TARGET_DIR"

# feishu2md stores credentials in its normal config file. Use a temporary HOME
# so credentials exist only for this GitHub Actions job.
export HOME="${RUNNER_TEMP:-/tmp}/feishu2md-home"
mkdir -p "$HOME"
feishu2md config --appId "$FEISHU_APP_ID" --appSecret "$FEISHU_APP_SECRET"

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "Downloading the configured Feishu document..."
feishu2md dl --output "$TMP_DIR" "$DOC_URL"

MD_FILE="$(find "$TMP_DIR" -type f -name '*.md' -print -quit)"
if [[ -z "${MD_FILE:-}" ]]; then
  echo "::error::feishu2md completed but no Markdown file was produced."
  exit 1
fi

# Copy all downloaded resources alongside the Markdown so relative image/file
# links emitted by feishu2md remain available.
cp -a "$TMP_DIR/." "$TARGET_DIR/"
DOWNLOADED_NAME="$(basename "$MD_FILE")"
DOWNLOADED_TARGET="$TARGET_DIR/$DOWNLOADED_NAME"
if [[ ! -f "$DOWNLOADED_TARGET" ]]; then
  echo "::error::Downloaded Markdown file was not found after copying."
  exit 1
fi

python3 - "$DOWNLOADED_TARGET" "$TARGET" "$WEIGHT" <<'PY'
import json
import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
weight = int(sys.argv[3])
body = source.read_text(encoding="utf-8")

# 将 feishu2md 输出的普通文本公式转换为 LaTeX
formula_replacements = [
    (
        "```\n样本缺失率 =\n该样本缺失的SNP数量 / SNP总数量\n```",
        r"\[\text{样本缺失率} = "
        r"\frac{\text{该样本缺失的 SNP 数量}}"
        r"{\text{SNP 总数量}}\]"
    ),
    (
        "```\nSNP缺失率 =\n该SNP缺失的样本数量 / 样本总数量\n```",
        r"\[\text{SNP 缺失率} = "
        r"\frac{\text{该 SNP 缺失的样本数量}}"
        r"{\text{样本总数量}}\]"
    ),
    (
        "```\nMAF = min(p, 1-p)\n```",
        r"\[\mathrm{MAF} = \min(p, 1-p)\]"
    )
]

for old, new in formula_replacements:
    if old not in body:
        print(f"公式未匹配，暂不替换：{old}")
        continue
    body = body.replace(old, new, 1)
    print("已转换一个数学公式")


# 飞书目录链接转换为本地页面锚点
link_targets = {
    "share-Vp35dp089ocTd4xmX5ycGt28nhe": (
        "1_Training_Trait_Data_2014_2021.csv", "training-trait-data"),
    "share-NLRJdf2Lvogg5Qxw4qHc3n84n6f": (
        "2_Training_Meta_Data_2014_2021.csv", "training-meta"),
    "share-GIbOdHiK5oQ0CzxnL32ceQZmnYb": (
        "3_Training_Soil_Data_2015_2021.csv", "training-soil"),
    "share-MykNdtxjmoxvL8xGJEwcglVrnfe": (
        "4_Training_Weather_Data_2014_2021.csv", "training-weather"),
    "share-Oa1Nd8rhNoPYpUxKIc8cAutMnNf": (
        "6_Training_EC_Data_2014_2021.csv", "training-ec"),
    "share-NDkRdyvXnoAUW7x2nLWcjrG1nzh": (
        "5_Genotype_Data_All_Years.vcf.zip", "training-genotype"),
    "share-KQ7HdH2EooeY3Fxgw9tc4ekXnHf": (
        "All_hybrid_names_info.csv", "hybrid-index"),
    "share-JLLCdDdU3oJ1crx84bqc32p3nRI": (
        "GenoDataSources.txt", "genotype-sources"),
    "share-LE09dyNZno6jjSxs1pEcFPEDnwf": (
        "GenoDataSourcesWithUpdatedBioProject.txt",
        "genotype-sources-updated"),
    "share-CXQ0dJhthon0rdxfpwfcaCAWnVb": (
        "1_Submission_Template_2022.csv", "testing-submission"),
    "share-QimMdMcEnoJSnIxnuJicKhm1n9b": (
        "2_Testing_Meta_Data_2022.csv", "testing-meta"),
    "share-WCQhdTEqJowT1Lx30xVckW7un8e": (
        "3_Testing_Soil_Data_2022.csv", "testing-soil"),
    "share-U404dJYEfoNR4OxxzfzcWao6nbv": (
        "4_Testing_Weather_Data_2022.csv", "testing-weather"),
    "share-VG0ad4qhPoWUNZx0DpWcsu9fnEc": (
        "6_Testing_EC_Data_2022.csv", "testing-ec"),
    "share-CapMdyzKqoXWsWxpyV9csWGen6d": (
        "Test_Set_Observed_Values_ANSWER.csv", "testing-answer"),
}

# 替换飞书链接
rewritten = set()

def replace_link(match):
    label, url = match.groups()
    fragment = url.partition("#")[2]

    if fragment not in link_targets:
        return match.group(0)

    rewritten.add(fragment)
    anchor = link_targets[fragment][1]
    return f"[{label}](#{anchor})"

body = re.sub(
    r"\[([^\]]+)\]\((https?://[^)]+)\)",
    replace_link,
    body
)

# 给对应章节标题添加本地锚点 ID
lines = body.splitlines()
found = set()

for i, line in enumerate(lines):
    if not line.startswith("#"):
        continue

    for fragment, (heading, anchor) in link_targets.items():
        if heading in line:
            lines[i] = f"{line.rstrip()} {{#{anchor}}}"
            found.add(anchor)
            break

missing = {
    anchor for _, anchor in link_targets.values()
} - found

if missing:
    raise SystemExit(
        f"未找到对应章节标题，无法生成本地目录锚点：{sorted(missing)}"
    )

body = "\n".join(lines)

print(f"本地目录链接转换成功：{len(rewritten)} 个")


match = re.search(r"(?m)^#\s+(.+?)\s*$", body)
title = match.group(1).strip() if match else "BreedingLab｜多源育种数据处理与智能组配"
if match:
    body = body[:match.start()] + body[match.end():]
body = body.lstrip("\n")

front_matter = (
    "---\n"
    f"title: {json.dumps(title, ensure_ascii=False)}\n"
    f"weight: {weight}\n"
    "language: zh\n"
    "---\n\n"
)
target.write_text(front_matter + body, encoding="utf-8")
if source != target:
    source.unlink()
print(f"Generated {target}")
PY

echo "Feishu document sync finished."
