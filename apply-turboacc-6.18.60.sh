#!/usr/bin/env bash
# 在 6.18.60 源码树（B / ponwrt-ZN504-HG5585F 内核栈）上适配 chenmozhijin/turboacc
#
# 用法：
#   ./apply-turboacc-6.18.60.sh <openwrt源码根>            # 默认 --no-sfe（推荐）
#   ./apply-turboacc-6.18.60.sh <openwrt源码根> --with-sfe  # 需要 Shortcut-FE 时
#
# 离线复用已解压源码：
#   --no-sfe   只需 TURBOACC_LUCI_DIR（指向含 luci-app-turboacc/ 的目录）
#   --with-sfe 另需 TURBOACC_PKG_DIR（指向含 hack-6.18/ 的 package 分支目录）
set -euo pipefail

TOP=${1:-.}
MODE=${2:---no-sfe}
SELF_DIR=$(cd "$(dirname "$0")" && pwd)

[ -d "$TOP/package" ] && [ -d "$TOP/target/linux/generic" ] || {
  echo "错误：$TOP 不是 OpenWrt 源码根目录"; exit 1; }
TOP=$(cd "$TOP" && pwd)

case "$MODE" in
  --no-sfe|--with-sfe) ;;
  *) echo "错误：模式只能是 --no-sfe 或 --with-sfe"; exit 1 ;;
esac

KV=$(sed -n 's/^LINUX_VERSION-6\.18[[:space:]]*=[[:space:]]*//p' "$TOP/target/linux/generic/kernel-6.18" 2>/dev/null | head -1)
echo "内核小版本: ${KV:-未知}  模式: $MODE"
[ "$KV" = ".60" ] || echo "⚠ 不是 .60，953 的 skbuff.h 上下文可能不适用，请先核对"

# ---------- 取 turboacc 源码 ----------
TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT
if [ -n "${TURBOACC_LUCI_DIR:-}" ]; then
  L=$TURBOACC_LUCI_DIR
  echo "使用本地 LuCI 源码: $L"
else
  echo "拉取 turboacc luci 分支 ..."
  curl -fsSL --max-time 180 "https://codeload.github.com/chenmozhijin/turboacc/tar.gz/refs/heads/luci" -o "$TD/luci.tgz"
  tar xzf "$TD/luci.tgz" -C "$TD"
  L="$TD/turboacc-luci"
fi
[ -f "$L/luci-app-turboacc/Makefile" ] || {
  echo "错误：$L 里没有 luci-app-turboacc/Makefile"; exit 1; }

# --no-sfe 完全不需要 package 分支：952/953/613/shortcut-fe 一个都不落。
# 原版 add_turboacc.sh 和早期适配脚本会无条件拉它，既浪费又在 package 分支
# 不可达时把整步带挂。只有 --with-sfe 才取。
if [ "$MODE" = "--with-sfe" ]; then
  if [ -n "${TURBOACC_PKG_DIR:-}" ]; then
    P=$TURBOACC_PKG_DIR
    echo "使用本地 package 源码: $P"
  else
    echo "拉取 turboacc package 分支 ..."
    curl -fsSL --max-time 180 "https://codeload.github.com/chenmozhijin/turboacc/tar.gz/refs/heads/package" -o "$TD/pkg.tgz"
    tar xzf "$TD/pkg.tgz" -C "$TD"
    P="$TD/turboacc-package"
  fi
  [ -d "$P/hack-6.18" ] || { echo "错误：$P 里没有 hack-6.18"; exit 1; }
fi

# ---------- 1/4 LuCI 包 ----------
mkdir -p "$TOP/package/turboacc"
rm -rf "$TOP/package/turboacc/luci-app-turboacc"
cp -a "$L/luci-app-turboacc" "$TOP/package/turboacc/"
test -f "$TOP/package/turboacc/luci-app-turboacc/Makefile" || {
  echo "错误：LuCI 包落地失败"; exit 1; }
echo "[1/4] luci-app-turboacc -> package/turboacc/"

# ---------- 2/4 用户态三包：绝不替换 ----------
# .60 树自带 fullcone 补丁链（firewall4 / nftables / libnftnl + fullconenat-nft），
# 且版本比 turboacc package 分支存档更新。原版 add_turboacc.sh 会把它们降级
# 并覆盖 001-firewall4-add-support-for-fullcone-nat.patch。
echo "[2/4] 跳过 firewall4 / nftables / libnftnl / nft-fullcone 替换（.60 树已自带 fullcone 链）"

HACK="$TOP/target/linux/generic/hack-6.18"
PEND="$TOP/target/linux/generic/pending-6.18"
mkdir -p "$HACK" "$PEND"

if [ "$MODE" = "--with-sfe" ]; then
  # B 自带的 952 与 turboacc 952 改同一批文件但结构布局不同，
  # 实测 B952 + 953 有 3 个 hunk FAILED，必须二选一。
  B952="$HACK/952-net-conntrack-events-support-multiple-registrant.patch"
  if [ -f "$B952" ]; then
    mv -f "$B952" "$B952.disabled"
    echo "[3/4] 禁用 B 自带 952 -> 952-...patch.disabled"
  fi
  cp -f "$P/hack-6.18/952-add-net-conntrack-events-support-multiple-registrant.patch" "$HACK/"

  # .60 适配版 953：上游加了 __u8 tc_depth:2;，原 hunk 上下文失配
  P953="$SELF_DIR/953-net-patch-linux-kernel-to-support-shortcut-fe-6.18.60.patch"
  if [ -f "$P953" ]; then
    cp -f "$P953" "$HACK/953-net-patch-linux-kernel-to-support-shortcut-fe.patch"
  else
    echo "警告：未找到 .60 版 953，回退用原版（skbuff.h hunk 会 FAILED）" >&2
    cp -f "$P/hack-6.18/953-net-patch-linux-kernel-to-support-shortcut-fe.patch" "$HACK/"
  fi
  cp -f "$P/pending-6.18/613-netfilter_optional_tcp_window_check.patch" "$PEND/"
  cp -a "$P/shortcut-fe" "$TOP/package/turboacc/"
  echo "[3/4] 952(turboacc) + 953(.60适配) + 613 + shortcut-fe 已就位"
  echo "[4/4] 完成。下一步：make target/linux/{clean,prepare} V=s 验证无 hunk FAILED"
else
  # B 自带 952 已提供 CONFIG_NF_CONNTRACK_CHAIN_EVENTS（fullconenat-nft 的
  # KCONFIG 需要它）；FLOW_OFFLOAD 用官方 kmod-nft-offload，BBR 用 951 BBRv3
  # + 官方 kmod-tcp-bbr，FULLCONE 用 B 的 fullconenat-nft (= kmod-nft-fullcone)。
  # 全部无需额外内核补丁。
  echo "[3/4] 不打 952/953/613（FLOW_OFFLOAD + BBR + FULLCONE 零内核补丁）"

  # 自检：确认 --no-sfe 没有把 --with-sfe 的残留带进来
  for bad in "$HACK/953-net-patch-linux-kernel-to-support-shortcut-fe.patch" \
             "$PEND/613-netfilter_optional_tcp_window_check.patch" \
             "$TOP/package/turboacc/shortcut-fe" \
             "$TOP/package/turboacc/nft-fullcone"; do
    [ -e "$bad" ] && { echo "警告：--no-sfe 却存在 $bad，请检查是否混用了 --with-sfe"; }
  done
  echo "[4/4] 完成。config 符号用 luci-app-turboacc_INCLUDE_* 前缀（见 enable-turboacc-ci.py）"
fi
