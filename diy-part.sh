#!/bin/bash
# Modify default IP
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate

# turboacc
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh && bash add_turboacc.sh

# ============ 双 WAN 网口布局（编译期定住）============
# 按你的实测拓扑调整这三个值
LAN_PORTS="lan4"     # 留作 LAN 的口
WAN_DEV="lan3"       # 主 WAN（移动 PPPoE 走的物理口）
WANB_DEV="lan2"      # 第二 WAN（电信光猫，192.168.3.x）

BOARD_D=target/linux/airoha/an7581/base-files/etc/board.d/02_network
if [ -f "$BOARD_D" ]; then
  cp -a "$BOARD_D" "$BOARD_D.orig"
  LAN_PORTS="$LAN_PORTS" WAN_DEV="$WAN_DEV" WANB_DEV="$WANB_DEV" python3 - <<'PY'
import io, os, sys
p = "target/linux/airoha/an7581/base-files/etc/board.d/02_network"
s = io.open(p, encoding="utf-8").read()
old = '''        fiberhome,hg5382a |\\
        nokia,xg-040g-md |\\
        nokia,xg-040g-md-ubi |\\
        nokia,xg-040g-tf-ubi |\\
        znxt,zn504xg-d)
            ucidef_set_interface_lan "lan1 lan2 lan3 lan4"
            ;;'''
new = '''        fiberhome,hg5382a |\\
        znxt,zn504xg-d)
            ucidef_set_interface_lan "lan1 lan2 lan3 lan4"
            ;;
        nokia,xg-040g-md |\\
        nokia,xg-040g-md-ubi |\\
        nokia,xg-040g-tf-ubi)
            ucidef_set_interface_lan "%s"
            ucidef_set_interface "wan"  device "%s" protocol "dhcp" metric "10"
            ucidef_set_interface "wanb" device "%s" protocol "dhcp" metric "20" defaultroute "0"
            ;;''' % (os.environ["LAN_PORTS"], os.environ["WAN_DEV"], os.environ["WANB_DEV"])
if old in s:
    io.open(p, "w", encoding="utf-8").write(s.replace(old, new))
    print("[dualwan] 02_network 已改写")
else:
    print("[dualwan] 警告：原文未匹配，跳过（上游可能已改）", file=sys.stderr)
PY
else
  echo "[dualwan] 警告：找不到 $BOARD_D" >&2
fi

# 第二 WAN 必须并入 wan 防火墙区，否则不通
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-dualwan-net <<'EOF'
#!/bin/sh
i=0
while uci -q get firewall.@zone[$i].name >/dev/null; do
  [ "$(uci -q get firewall.@zone[$i].name)" = "wan" ] && {
    uci -q set firewall.@zone[$i].network="wan wanb"
    uci commit firewall
    break
  }
  i=$((i+1))
done
exit 0
EOF
chmod +x files/etc/uci-defaults/99-dualwan-net
