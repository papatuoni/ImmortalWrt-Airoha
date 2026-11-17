#!/usr/bin/env bash
# STEP 1 · 收集 A 的基线产物（本地 / GitHub Actions 双模，纯只读）
#
# 用法:
#   本地:   bash scripts/collect-baseline.sh <源码树> <输出目录> <本仓库> local
#   CI:     bash scripts/collect-baseline.sh <源码树> <输出目录> <本仓库> actions
#   兼容:   只给前两个参数时，按 GITHUB_ACTIONS 自动判定（旧 workflow 片段可直接用）
#
# 这份替换上一版只认 GITHUB_* 的 collect-baseline.sh。
# 放到仓库: scripts/collect-baseline.sh  (chmod +x)
set -euo pipefail

SRC="${1:-${OPENWRT_PATH:-openwrt}}"
OUT="${2:-baseline-out}"
REPO_ROOT="${3:-${GITHUB_WORKSPACE:-$(pwd)}}"
ORIGIN="${4:-}"
if [ -z "$ORIGIN" ]; then
    if [ "${GITHUB_ACTIONS:-false}" = "true" ]; then ORIGIN="actions"; else ORIGIN="local"; fi
fi

EXPECTED_COMMIT="${EXPECTED_SOURCE_COMMIT:-41d7b64f938093072673163ecf63e62bc5faecb6}"

mkdir -p "$OUT/raw" "$OUT/golden" "$OUT/dtb"
log()  { echo "::notice::[baseline] $*"; }
warn() { echo "::warning::[baseline] $*"; }
die()  { echo "::error::[baseline] $*"; exit 1; }
note() { [ "$ORIGIN" = "actions" ] && echo "::notice::[baseline] $*" || echo "[baseline] $*"; }

[ -d "$SRC" ] || die "找不到源码树: $SRC"
[ -d "$REPO_ROOT" ] || die "找不到本仓库: $REPO_ROOT"

# ── 1. 源码 commit（第一步的核心） ────────────────────────────────────────
SOURCE_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
SOURCE_DATE="$(git -C "$SRC" show -s --format=%cI HEAD)"
SOURCE_BRANCH="$(git -C "$SRC" rev-parse --abbrev-ref HEAD)"
A_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "$SOURCE_COMMIT" > "$OUT/SOURCE_COMMIT"
note "源码 commit = $SOURCE_COMMIT ($SOURCE_DATE)  origin=$ORIGIN"
if [ "$SOURCE_COMMIT" != "$EXPECTED_COMMIT" ]; then
    warn "源码 commit 不是冻结值 $EXPECTED_COMMIT —— 本次只能算工作基线，不能冒充 golden"
fi

# ── 2. 配置与包集合 ──────────────────────────────────────────────────────
[ -f "$SRC/.config" ] || die "缺 .config，说明 defconfig 没跑成功"
cp "$SRC/.config" "$OUT/raw/.config"
[ -f "$SRC/tmp/.packageinfo" ] && cp "$SRC/tmp/.packageinfo" "$OUT/raw/packageinfo" || true
for f in feeds.conf feeds.conf.default; do
    [ -f "$SRC/$f" ] && cp "$SRC/$f" "$OUT/raw/$f" || true
done
[ -f "$SRC/target/linux/airoha/Makefile" ] && \
    cp "$SRC/target/linux/airoha/Makefile" "$OUT/raw/airoha-Makefile" || true
[ -f "$SRC/target/linux/airoha/an7581/config-6.18" ] && \
    cp "$SRC/target/linux/airoha/an7581/config-6.18" "$OUT/raw/config-6.18" || true

# ── 3. 产物 manifest / sha256sums / profiles ─────────────────────────────
BT="$SRC/bin/targets"
if [ -d "$BT" ]; then
    find "$BT" -type f \
      \( -name '*.manifest' -o -name 'sha256sums' -o -name 'profiles.json' \) \
      -print0 2>/dev/null | while IFS= read -r -d '' f; do
        cp "$f" "$OUT/raw/$(basename "$f")"
      done || true
else
    warn "bin/targets 不存在（--config-only 或编译失败？），manifest 段留空"
fi

# ── 4. DTB 与漂移检查产物 ────────────────────────────────────────────────
for f in dtb.log refresh.log; do
    [ -f "$REPO_ROOT/$f" ] && cp "$REPO_ROOT/$f" "$OUT/$f" || true
done
if [ -d "$REPO_ROOT/golden" ]; then cp -a "$REPO_ROOT/golden/." "$OUT/golden/"; fi
if [ -d "$SRC/build_dir" ]; then
    find "$SRC/build_dir" -type f -name '*xg-040g-md*.dtb' -print0 2>/dev/null |
      head -z -n 10 | while IFS= read -r -d '' f; do
        cp "$f" "$OUT/dtb/$(basename "$f")"
      done || true
fi

# ── 5. 静态检查：rpcd / init.d 执行位 ────────────────────────────────────
EXEC_BAD=""
if [ -d "$REPO_ROOT/packages" ]; then
    EXEC_BAD="$(find "$REPO_ROOT/packages" -type f \
      \( -path '*/root/usr/libexec/rpcd/*' -o -path '*/root/etc/init.d/*' \) \
      ! -perm -u+x -printf '%p ' 2>/dev/null || true)"
fi
[ -z "$EXEC_BAD" ] || die "以下脚本缺可执行位: $EXEC_BAD"

# ── 6. 内核 / 工具链元信息 ───────────────────────────────────────────────
KERNEL_PATCHVER="$(sed -n 's/^KERNEL_PATCHVER[^=]*:=//p' "$SRC/target/linux/airoha/Makefile" 2>/dev/null | head -1 | tr -d ' ' || true)"
UBOOT_VER="$(sed -n 's/^PKG_VERSION:=//p' "$SRC/package/boot/uboot-airoha/Makefile" 2>/dev/null | head -1 | tr -d ' ' || true)"

# ── 7. 生成 baseline.json ────────────────────────────────────────────────
python3 - "$OUT" "$ORIGIN" "$SOURCE_COMMIT" "$SOURCE_DATE" "$SOURCE_BRANCH" \
    "$A_COMMIT" "$EXPECTED_COMMIT" "$KERNEL_PATCHVER" "$UBOOT_VER" <<'PY'
import json, hashlib, os, sys, glob
out, origin, commit, date, branch, a_commit, expected, kpv, uboot = sys.argv[1:10]
def sha(p):
    if not p or not os.path.isfile(p): return None
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for c in iter(lambda:f.read(1<<20),b''): h.update(c)
    return h.hexdigest()
cfg=os.path.join(out,'raw','.config')
man=next(iter(sorted(glob.glob(os.path.join(out,'raw','*.manifest')))),None)
data={
 "step":"1-freeze-A-baseline",
 "origin":origin,                       # local=工作基线 / actions=黄金基线，两者不可互相冒充
 "generated_by":"scripts/collect-baseline.sh",
 "source_repo":os.environ.get("REPO_URL","https://github.com/Loong1996/immortalwrt.git"),
 "source_branch":branch,
 "source_commit":commit,
 "source_commit_date":date,
 "expected_source_commit":expected,
 "match_expected":(commit==expected),
 "a_repo_commit":a_commit,
 "run_id":os.environ.get("GITHUB_RUN_ID"),
 "run_number":os.environ.get("GITHUB_RUN_NUMBER"),
 "device":os.environ.get("DEVICE","xg-040g-md"),
 "device_variant":os.environ.get("DEVICE_VARIANT","ubi"),
 "dram_size":os.environ.get("DRAM_SIZE","auto"),
 "config_file":os.environ.get("CONFIG_FILE","config/xg-040g-md-master.config"),
 "kernel_patchver":kpv,
 "uboot_airoha_version":uboot,
 "config_sha256":sha(cfg),
 "manifest_file":os.path.basename(man) if man else None,
 "manifest_sha256":sha(man) if man else None,
 "dtb_golden_dir":"golden/",
 "files":sorted(os.path.relpath(p,out) for p in glob.glob(out+'/**/*',recursive=True)
                if os.path.isfile(p) and not p.endswith(('BASELINE.sha256','baseline.json'))),
}
with open(os.path.join(out,'baseline.json'),'w') as f:
    json.dump(data,f,ensure_ascii=False,indent=2)
print("config_sha256=",data["config_sha256"])
print("manifest_sha256=",data["manifest_sha256"])
print("match_expected=",data["match_expected"])
PY

# ── 8. 总校验和 ──────────────────────────────────────────────────────────
( cd "$OUT" && find . -type f ! -name 'BASELINE.sha256' -print0 |
    sort -z | xargs -0 sha256sum > BASELINE.sha256 )
note "基线产物齐了: $OUT ($(find "$OUT" -type f | wc -l) 文件)"
note "下一步：把 config_sha256 / manifest_sha256 / DTB 结论回填 baseline.lock"
