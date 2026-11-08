#!/bin/bash
# Modify default IP
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate

# turboacc
curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh && bash add_turboacc.sh

# 双 WAN 网口布局 —— 仓库的 DIY 注入本来就由本脚本承担，不另建脚本。
#   lan1 = pppoe-wan：PPPoE 拨号，账号密码默认空白（不预填、不需要输入），
#                      刷机后在 LuCI「网络 → 接口 → WAN」自己填
#   lan2 = wanb：DHCP 客户端，电信出口 / 默认路由
#   lan3 + lan4 = br-lan（局域网，192.168.2.1）
# 只写 files/，不碰 feeds：smartdns 的 Makefile 改写必须等 Install Feeds 之后。
mkdir -p files/etc/config files/etc/uci-defaults

cat > files/etc/config/network <<'NETEOF'
config device
        option name 'br-lan'
        option type 'bridge'
        list ports 'lan3'
        list ports 'lan4'

config interface 'lan'
        option device 'br-lan'
        option proto 'static'
        option ipaddr '192.168.2.1'
        option netmask '255.255.255.0'
        option ip6assign '60'

# lan1：PPPoE 拨号 WAN（pppoe-wan），账号密码默认空白
config interface 'wan'
        option device 'lan1'
        option proto 'pppoe'
        option username ''
        option password ''
        option peerdns '0'
        option metric '20'
        option defaultroute '0'

# lan2：DHCP 客户端，电信出口，默认路由
config interface 'wanb'
        option device 'lan2'
        option proto 'dhcp'
        option peerdns '0'
        option metric '10'
        option defaultroute '1'
NETEOF

cat > files/etc/uci-defaults/99-dualwan-net <<'UCEOF'
#!/bin/sh
# 首次启动 board.d/02_network 会把 lan1~lan4 全设成 LAN，这里兜底回定制布局。
# 执行成功后 OpenWrt 会删除本脚本。
uci -q get network.wan >/dev/null 2>&1 || uci -q set network.wan=interface
uci -q set network.wan.device='lan1'
uci -q set network.wan.proto='pppoe'
uci -q set network.wan.username=''
uci -q set network.wan.password=''
uci -q set network.wan.peerdns='0'
uci -q set network.wan.metric='20'
uci -q set network.wan.defaultroute='0'

uci -q get network.wanb >/dev/null 2>&1 || uci -q set network.wanb=interface
uci -q set network.wanb.device='lan2'
uci -q set network.wanb.proto='dhcp'
uci -q set network.wanb.peerdns='0'
uci -q set network.wanb.metric='10'
uci -q set network.wanb.defaultroute='1'

i=0
while uci -q get "network.@device[$i]" >/dev/null 2>&1; do
    if [ "$(uci -q get "network.@device[$i].name")" = "br-lan" ]; then
        uci -q delete "network.@device[$i].ports"
        uci -q add_list "network.@device[$i].ports"='lan3'
        uci -q add_list "network.@device[$i].ports"='lan4'
        break
    fi
    i=$((i+1))
done

i=0
found=0
while uci -q get "firewall.@zone[$i].name" >/dev/null 2>&1; do
    if [ "$(uci -q get "firewall.@zone[$i].name")" = "wan" ]; then
        uci -q set "firewall.@zone[$i].network"='wan wanb'
        found=1
        break
    fi
    i=$((i+1))
done
[ "$found" = "1" ] || echo "dualwan: 未找到 wan 区" >&2
uci commit network
uci commit firewall
exit 0
UCEOF
chmod +x files/etc/uci-defaults/99-dualwan-net

[ -s files/etc/config/network ] || { echo "错误: network 写入失败" >&2; exit 1; }
[ -s files/etc/uci-defaults/99-dualwan-net ] || { echo "错误: uci-defaults 写入失败" >&2; exit 1; }
echo "----- 最终 network（PPPoE 账号密码为空）-----"
cat files/etc/config/network
echo "---------------------------------------------"
