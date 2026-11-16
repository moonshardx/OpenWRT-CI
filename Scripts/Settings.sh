#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "/attendedsysupgrade/d" {} +
#修改默认主题
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" {} +
#修改immortalwrt.lan关联IP
find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" -exec sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" {} +
#添加编译日期标识
find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" -exec sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" {} +

#修改默认WIFI账号密码
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
ROUTER_TOOL="./package/emortal/luci-app-router-tool/root/etc/config/router-tool"
for file in "$ROUTER_TOOL" "$WIFI_UC"; do
	[ -f "$file" ] && sed -i "s/ssid '.*'/ssid '$WRT_SSID'/g; s/key '.*'/key '$WRT_WORD'/g" "$file"
done

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#无WIFI配置调整Q6大小
	if [[ "$WRT_WIFI" == "WIFI-NO" ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
fi

#X86 预设 4 口网络布局：eth0/eth1/eth2=LAN 桥, eth3=WAN(PPPoE)；LAN IP 192.168.66.1
#通过首刷执行一次的 uci-defaults 注入（跑完自删）；PPPoE 账密故意不写，刷完在 LuCI 里填
if [[ "${WRT_CONFIG^^}" == *"X86"* ]]; then
	mkdir -p ./files/etc/uci-defaults
	cat > ./files/etc/uci-defaults/99-custom-network <<'DEFAULTS'
#!/bin/sh
# 清除 config_generate 自动生成的 bridge 设备段后重建，避免口序不一致
while uci -q delete network.@device[0]; do :; done
uci batch <<'EOF'
add network device
set network.@device[-1].name='br-lan'
set network.@device[-1].type='bridge'
add_list network.@device[-1].ports='eth0'
add_list network.@device[-1].ports='eth1'
add_list network.@device[-1].ports='eth2'
set network.lan=interface
set network.lan.device='br-lan'
set network.lan.proto='static'
set network.lan.ipaddr='192.168.66.1'
set network.lan.netmask='255.255.255.0'
set network.lan.ip6assign='64'
set network.wan=interface
set network.wan.device='eth3'
set network.wan.proto='pppoe'
set network.wan.ipv6='0'
EOF
uci -q delete network.wan6
uci commit network
exit 0
DEFAULTS
	echo "x86 custom network (eth0/1/2=LAN br, eth3=WAN pppoe, 192.168.66.1) injected!"
fi
