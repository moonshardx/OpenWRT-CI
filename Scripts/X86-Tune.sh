#!/bin/sh
# =============================================================================
# Network Turbo Optimization Script v5.9
# Target: ImmortalWrt 25.12 + Intel N100 + Mihomo + PPPoE + SQM
# =============================================================================
# 不使用 set -e，允许部分命令失败而继续执行

# DESTDIR 用于固件构建，仅生成文件，不执行路由器配置命令。
DESTDIR=${DESTDIR:-}
mkdir -p "$DESTDIR/etc/init.d" "$DESTDIR/etc/hotplug.d/net" || exit 1

# Part 0: Conntrack 模块参数 (需在模块加载前设置)
setup_conntrack_module() {
    MODPROBE_CONF="/etc/modprobe.d/nf_conntrack.conf"
    if [ ! -f "$MODPROBE_CONF" ]; then
        mkdir -p /etc/modprobe.d
        cat > "$MODPROBE_CONF" << 'MODCONF'
# hashsize = nf_conntrack_max / 4
options nf_conntrack hashsize=65536
MODCONF
        echo "[Setup] Created $MODPROBE_CONF (effective after reboot)"
    fi
}

# Part 0.5: irqbalance
# 检测物理网卡中断是否已由内核(MSI-X managed)分散到多核。多队列网卡(igc/ixgbe/NVMe 等)
# 的中断在驱动初始化时被内核一队一核钉死且为 managed, irqbalance 既改不动也无需改,
# 此时启用它只会空转并刷 "Operation not permitted" 日志。
nic_irqs_distributed() {
    local dev irqs="" cores
    for dev in /sys/class/net/eth*; do
        [ -e "$dev/device/msi_irqs" ] || continue
        irqs="$irqs $(ls "$dev/device/msi_irqs" 2>/dev/null)"
    done
    irqs=$(echo $irqs | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u)
    [ -z "$irqs" ] && return 1   # 未发现多队列网卡中断 → 无法判定, 走常规逻辑
    cores=$(for i in $irqs; do cat "/proc/irq/$i/effective_affinity_list" 2>/dev/null; done \
            | tr ',' '\n' | sort -u | grep -c .)
    [ "${cores:-0}" -ge 2 ]      # 已铺到 >=2 个核 → 视为内核已分散
}

setup_irqbalance() {
    # 网卡中断已被内核托管并分散到多核 → irqbalance 无意义: 停用以免空转与日志噪声
    if nic_irqs_distributed; then
        echo "[Setup] NIC IRQs already kernel-managed across cores; irqbalance redundant."
        if [ -x /etc/init.d/irqbalance ]; then
            /etc/init.d/irqbalance disable 2>/dev/null
            /etc/init.d/irqbalance stop 2>/dev/null
            echo "[Setup] Disabled irqbalance (no-op on managed MSI-X multi-queue NICs)."
        fi
        return
    fi

    if [ ! -x /etc/init.d/irqbalance ]; then
        echo "[Setup] irqbalance not installed, attempting to install..."
        if command -v opkg >/dev/null 2>&1; then
            opkg update >/dev/null 2>&1
            if opkg install irqbalance >/dev/null 2>&1; then
                echo "[Setup] irqbalance installed successfully"
            else
                echo "[Setup] Warning: Failed to install irqbalance, skipping..."
                return
            fi
        else
            echo "[Setup] Warning: opkg not available, cannot install irqbalance"
            return
        fi
    fi

    if [ -x /etc/init.d/irqbalance ]; then
        IRQ_NEED_RESTART=0

        if command -v uci >/dev/null 2>&1; then
            IRQ_UCI_ENABLED="$(uci -q get irqbalance.@irqbalance[0].enabled)"
            if [ "$IRQ_UCI_ENABLED" != "1" ]; then
                uci set irqbalance.@irqbalance[0].enabled='1'
                uci commit irqbalance
                IRQ_NEED_RESTART=1
                echo "[Setup] Set irqbalance enabled=1 in UCI config"
            fi
        fi

        if ! /etc/init.d/irqbalance enabled 2>/dev/null; then
            /etc/init.d/irqbalance enable 2>/dev/null || echo "[Setup] Warning: Failed to enable irqbalance"
            echo "[Setup] Enabled irqbalance service"
        fi

        # busybox 的 pgrep -x 对 irqbalance 匹配不稳定，去掉 -x
        IRQ_RUNNING=0
        if command -v pgrep >/dev/null 2>&1; then
            pgrep irqbalance >/dev/null 2>&1 && IRQ_RUNNING=1
        elif command -v pidof >/dev/null 2>&1; then
            pidof irqbalance >/dev/null 2>&1 && IRQ_RUNNING=1
        fi

        if [ "$IRQ_NEED_RESTART" -eq 1 ]; then
            /etc/init.d/irqbalance restart 2>/dev/null || /etc/init.d/irqbalance start 2>/dev/null
            echo "[Setup] irqbalance restarted with new config"
        elif [ "$IRQ_RUNNING" -eq 0 ]; then
            /etc/init.d/irqbalance start 2>/dev/null
            echo "[Setup] irqbalance started"
        else
            echo "[Setup] irqbalance is already running"
        fi
    fi
}

# 主服务脚本生成 (/etc/init.d/net_turbo)
cat << 'EOF' > "$DESTDIR/etc/init.d/net_turbo"
#!/bin/sh /etc/rc.common
# Network Optimization for Intel N100 (v5.9)
# TUN+TProxy, PPPoE, SQM (CAKE+NAT), RPS/XPS, Kernel Tuning

START=99

stop() {
    echo "Network Turbo stopped. Settings persist until reboot."
}

boot() {
    start
}

safe_write() {
    if [ -w "$2" ]; then
        echo "$1" > "$2" 2>/dev/null
    fi
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# 获取 WAN 设备 (支持 PPPoE，自动检测接口名)
get_wan_devices() {
    WAN_DEV="$(uci get network.wan.device 2>/dev/null)"
    if [ -z "$WAN_DEV" ]; then
        WAN_DEV="$(uci get network.wan.ifname 2>/dev/null)"
    fi

    PPPOE_DEV=""
    WAN_PHYS=""

    WAN_PROTO="$(uci get network.wan.proto 2>/dev/null)"
    if [ "$WAN_PROTO" = "pppoe" ]; then
        for ppp_if in /sys/class/net/pppoe-* /sys/class/net/ppp[0-9]*; do
            if [ -d "$ppp_if" ]; then
                PPPOE_DEV="$(basename "$ppp_if")"
                break
            fi
        done
        [ -z "$PPPOE_DEV" ] && PPPOE_DEV="pppoe-wan"
        WAN_PHYS="$WAN_DEV"
    else
        WAN_PHYS="$WAN_DEV"
    fi

    # 物理接口未知时从 lower_* 链接获取
    if [ -z "$WAN_PHYS" ] && [ -n "$PPPOE_DEV" ] && [ -d "/sys/class/net/$PPPOE_DEV" ]; then
        for lower in /sys/class/net/"$PPPOE_DEV"/lower_*; do
            [ -e "$lower" ] && WAN_PHYS="$(basename "$lower" | sed 's/^lower_//')"
            [ -n "$WAN_PHYS" ] && break
        done
    fi
}

# 检测 TUN 设备 (mihomo/clash: utun, tun0, tun1)
detect_tun_device() {
    TUN_DEV=""
    for candidate in utun tun0 tun1 mihomo; do
        if [ -d "/sys/class/net/$candidate" ]; then
            TUN_DEV="$candidate"
            break
        fi
    done
}

# 系统日志迁到 tmpfs，避免 overlay 闪存磨损 (重启丢日志可接受)
setup_syslog_to_tmpfs() {
    have_cmd uci || return 0
    CURRENT_LOG_FILE="$(uci -q get system.@system[0].log_file)"

    # 已在 tmpfs (/tmp 或 /var/log) 则跳过
    case "$CURRENT_LOG_FILE" in
        /tmp/*|/var/log/*|"")
            return 0
            ;;
    esac

    uci set system.@system[0].log_file='/tmp/syslog'
    uci commit system
    [ -x /etc/init.d/log ] && /etc/init.d/log restart >/dev/null 2>&1
    [ -f "$CURRENT_LOG_FILE" ] && rm -f "$CURRENT_LOG_FILE" "${CURRENT_LOG_FILE}.old"
    echo "  [Logging] Migrated syslog: $CURRENT_LOG_FILE -> /tmp/syslog (reduce flash wear)"
}

# 中和空转的 appfilter daemon (enable=0 但服务仍启用时会与关闭 flow_offloading 拉锯刷日志)
neutralize_appfilter() {
    [ -x /etc/init.d/appfilter ] || return 0

    AF_UCI_ENABLE="$(uci -q get appfilter.global.enable)"
    # 仅当功能层禁用但服务层仍启用时才干预 (用户在用则不动)
    if [ "$AF_UCI_ENABLE" = "0" ] && /etc/init.d/appfilter enabled 2>/dev/null; then
        /etc/init.d/appfilter stop >/dev/null 2>&1
        /etc/init.d/appfilter disable >/dev/null 2>&1
        [ -f /var/log/appfilter.log ] && : > /var/log/appfilter.log
        echo "  [Cleanup] Neutralized stale appfilter daemon (was fighting flow_offloading)"
    fi
}

start() {
    echo "Starting Network Turbo Optimization (v5.9)..."

    # 先获取设备信息 (必须在其他配置之前)
    get_wan_devices
    detect_tun_device

    # 先处理 appfilter/syslog (避免与 flow_offloading 拉锯 / overlay 磨损)
    neutralize_appfilter
    setup_syslog_to_tmpfs

    # Part 1: 防火墙与分流 (eBPF 兼容 + MSS 修复)
    NEED_COMMIT=0

    # 1.0 Packet Steering (多核软件收包)
    CURRENT_PS=$(uci get network.globals.packet_steering 2>/dev/null)
    if [ "$CURRENT_PS" != "2" ]; then
        uci set network.globals.packet_steering='2'
        echo "  [Network] Enabled Packet Steering on all four cores."
    fi

    # 1.1 关闭 flow_offloading (与 TProxy/eBPF 冲突)
    for opt in flow_offloading flow_offloading_hw; do
        CURRENT_VAL=$(uci get firewall.@defaults[0].$opt 2>/dev/null)
        if [ "$CURRENT_VAL" != "0" ]; then
            uci set firewall.@defaults[0].$opt='0'
            NEED_COMMIT=1
            echo "  [Firewall] Disabled $opt for TProxy stability."
        fi
    done

    # 1.2 Full Cone NAT (P2P/游戏穿透)
    CURRENT_FC=$(uci get firewall.@defaults[0].fullcone 2>/dev/null)
    if [ -n "$CURRENT_FC" ] && [ "$CURRENT_FC" != "1" ]; then
        uci set firewall.@defaults[0].fullcone='1'
        NEED_COMMIT=1
        echo "  [Firewall] Enabled Full Cone NAT."
    fi

    # 1.3 MSS 钳制 (PPPoE MTU 兼容, fw4 zone 级 mtu_fix)
    WAN_ZONE_IDX=""
    i=0
    while uci -q get firewall.@zone[$i] >/dev/null 2>&1; do
        ZONE_NAME=$(uci get firewall.@zone[$i].name 2>/dev/null)
        if [ "$ZONE_NAME" = "wan" ]; then
            WAN_ZONE_IDX=$i
            break
        fi
        i=$((i + 1))
    done

    if [ -n "$WAN_ZONE_IDX" ]; then
        CURRENT_MTU_FIX=$(uci get firewall.@zone[$WAN_ZONE_IDX].mtu_fix 2>/dev/null)
        if [ "$CURRENT_MTU_FIX" != "1" ]; then
            uci set firewall.@zone[$WAN_ZONE_IDX].mtu_fix='1'
            NEED_COMMIT=1
            echo "  [Firewall] Enabled MSS clamping (mtu_fix) on WAN zone."
        fi
    else
        echo "  [Firewall] Warning: WAN zone not found, skipping MSS clamping."
    fi

    if [ "$NEED_COMMIT" -eq 1 ]; then
        uci commit firewall
        /etc/init.d/firewall reload
        echo "  [Firewall] Config reloaded."
    fi

    if [ "$CURRENT_PS" != "2" ]; then
        uci commit network
    fi
    /etc/init.d/packet_steering reload

    # Part 1.5: TUN+TProxy 必备模块与 rp_filter
    if have_cmd modprobe; then
        for mod in tun nft_tproxy nft_socket nf_conntrack_netlink; do
            modprobe "$mod" 2>/dev/null && echo "  [Module] Loaded $mod"
        done
    fi

    # 禁用 rp_filter (TUN/TProxy 混合模式必须; 会降低源地址验证强度)
    if [ -d /proc/sys/net/ipv4/conf ]; then
        safe_write "0" "/proc/sys/net/ipv4/conf/all/rp_filter"
        safe_write "0" "/proc/sys/net/ipv4/conf/default/rp_filter"
        for virt_if in "$TUN_DEV" tun0 utun lo "$PPPOE_DEV"; do
            [ -n "$virt_if" ] && [ -f "/proc/sys/net/ipv4/conf/$virt_if/rp_filter" ] && \
                safe_write "0" "/proc/sys/net/ipv4/conf/$virt_if/rp_filter"
        done
        echo "  [Kernel] Disabled rp_filter for TProxy (selective)."
    fi

    # Part 1.6: 清理旧版 dhcp_guard (功能已移除, 幂等卸载旧部署)
    cleanup_legacy_dhcp_guard() {
        LEGACY_FOUND=0
        if have_cmd nft && nft delete table bridge dhcp_guard 2>/dev/null; then
            LEGACY_FOUND=1
        fi
        if [ -f /etc/dhcp-guard.nft ]; then
            rm -f /etc/dhcp-guard.nft
            LEGACY_FOUND=1
        fi
        if [ -f /etc/rc.local ] && grep -q "dhcp-guard.nft" /etc/rc.local 2>/dev/null; then
            sed -i '/dhcp-guard\.nft/d' /etc/rc.local 2>/dev/null
            LEGACY_FOUND=1
        fi
        [ "$LEGACY_FOUND" = "1" ] && echo "  [Cleanup] Removed legacy dhcp_guard (nft table / file / rc.local)"
    }

    cleanup_legacy_dhcp_guard

    # Part 2: CPU 调频 (intel_pstate active+HWP: powersave=硬件自适应智能调度, 非锁低频)
    for cpu_gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        safe_write "powersave" "$cpu_gov"
    done
    # EPP=balance_performance: 空闲降频省电, 有负载 HWP 微秒级拉满, 兼顾延迟与功耗
    for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        safe_write "balance_performance" "$epp"
    done
    echo "  [CPU] Set governor=powersave + EPP=balance_performance (HWP adaptive)."

    # Part 3: 网卡队列优化 (Smart RPS/XPS)
    CPU_MASK="f"  # 4 Cores for N100 (binary: 1111)

    # mihomo TUN MTU (1420 基准 / 1460 ≈0% / 1480 +1.5% / 1492 -27%; 取 1460 更保守, 避免 PMTU 变化时黑洞; mihomo tun.mtu 会被覆盖, 需内核侧强制)
    TUN_MTU=1460

    # 3.1 物理网卡 XPS (发送队列绑定所有核心)
    for net_path in /sys/class/net/*; do
        dev_name=$(basename "$net_path")
        if [ ! -e "$net_path/device" ] || [ "$dev_name" = "lo" ]; then
            continue
        fi
        for xps_file in "$net_path"/queues/tx-*/xps_cpus; do
            safe_write "$CPU_MASK" "$xps_file"
        done
    done
    echo "  [NIC] Configured XPS for physical interfaces."

    # 3.2 虚拟接口 RPS (PPPoE/TUN/VPN 收包分散软中断)
    for virt_dev in "$PPPOE_DEV" "$TUN_DEV" tun0 utun wg0 tailscale0; do
        [ -z "$virt_dev" ] && continue
        if [ -d "/sys/class/net/$virt_dev" ]; then
            for rps_file in "/sys/class/net/$virt_dev"/queues/rx-*/rps_cpus; do
                safe_write "$CPU_MASK" "$rps_file"
            done
            echo "  [NIC] Configured RPS for $virt_dev"
        fi
    done

    # 强制 mihomo TUN 到实测最佳 MTU
    if [ -n "$TUN_DEV" ] && [ -d "/sys/class/net/$TUN_DEV" ]; then
        CURRENT_TUN_MTU="$(cat /sys/class/net/$TUN_DEV/mtu 2>/dev/null)"
        if [ "$CURRENT_TUN_MTU" != "$TUN_MTU" ]; then
            ip link set "$TUN_DEV" mtu "$TUN_MTU" 2>/dev/null && \
                echo "  [NIC] Forced $TUN_DEV MTU: $CURRENT_TUN_MTU -> $TUN_MTU (measured optimum)"
        fi
    fi

    # 3.3 RPS Flow Table (减少软中断抖动)
    safe_write "32768" "/proc/sys/net/core/rps_sock_flow_entries"
    for rps_dev in "$PPPOE_DEV" "$TUN_DEV" tun0 utun wg0 tailscale0; do
        [ -z "$rps_dev" ] && continue
        if [ -d "/sys/class/net/$rps_dev" ]; then
            for rps_flow_cnt in /sys/class/net/"$rps_dev"/queues/rx-*/rps_flow_cnt; do
                safe_write "4096" "$rps_flow_cnt"
            done
        fi
    done
    echo "  [NIC] Configured RPS flow tables."

    # 3.4 Intel i225/i226 关闭 LRO (TProxy 兼容)
    if [ -n "$WAN_PHYS" ] && have_cmd ethtool; then
        DRIVER="$(ethtool -i "$WAN_PHYS" 2>/dev/null | awk '/driver:/ {print $2}')"
        if [ "$DRIVER" = "igc" ] || [ "$DRIVER" = "e1000e" ]; then
            ethtool -K "$WAN_PHYS" lro off >/dev/null 2>&1
            echo "  [NIC] Disabled LRO on $WAN_PHYS ($DRIVER) for TProxy stability."
        fi
    fi

    # 3.5 UDP GRO 转发 (物理 WAN, for Tailscale/WireGuard)
    if [ -n "$WAN_PHYS" ] && have_cmd ethtool; then
        ethtool -K "$WAN_PHYS" rx-udp-gro-forwarding on 2>/dev/null && \
            echo "  [NIC] Enabled UDP GRO forwarding on $WAN_PHYS"
        ethtool -K "$WAN_PHYS" rx-gro-list off 2>/dev/null && \
            echo "  [NIC] Disabled rx-gro-list on $WAN_PHYS for Tailscale/WireGuard"
    fi

    # Part 4: TCP/BBR 优化
    BBR_AVAILABLE=0
    if have_cmd modprobe && modprobe tcp_bbr 2>/dev/null; then
        BBR_AVAILABLE=1
    elif [ -r /proc/sys/net/ipv4/tcp_available_congestion_control ] && \
        grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        BBR_AVAILABLE=1
    fi

    # default_qdisc: 优先 fq (BBR 最佳搭档), 无 sch_fq 时退回 fq_codel; 仅影响本机流量
    DEFAULT_QDISC="fq_codel"
    if [ -d /sys/module/sch_fq ]; then
        DEFAULT_QDISC="fq"
    elif have_cmd modprobe && modprobe sch_fq 2>/dev/null; then
        DEFAULT_QDISC="fq"
    fi
    safe_write "$DEFAULT_QDISC" "/proc/sys/net/core/default_qdisc"
    echo "  [Kernel] Set default_qdisc=$DEFAULT_QDISC"

    if [ "$BBR_AVAILABLE" -eq 1 ]; then
        safe_write "bbr" "/proc/sys/net/ipv4/tcp_congestion_control"
        echo "  [Kernel] Set tcp_congestion_control=bbr"
    else
        echo "  [Kernel] Warning: BBR not available, keeping current congestion control"
    fi

    # TCP Fast Open (3 = client+server)
    safe_write "3" "/proc/sys/net/ipv4/tcp_fastopen"
    echo "  [Kernel] Set tcp_fastopen=3 (client+server)"

    # TCP buffer (代理高并发, 中位 1MB)
    sysctl -w net.core.rmem_max=33554432 >/dev/null 2>&1
    sysctl -w net.core.wmem_max=33554432 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 1048576 33554432" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 1048576 33554432" >/dev/null 2>&1

    # UDP buffer (代理/QUIC/WireGuard, 防丢包)
    sysctl -w net.core.rmem_default=262144 >/dev/null 2>&1
    sysctl -w net.core.wmem_default=262144 >/dev/null 2>&1
    sysctl -w net.ipv4.udp_rmem_min=16384 >/dev/null 2>&1
    sysctl -w net.ipv4.udp_wmem_min=16384 >/dev/null 2>&1

    # 连接队列 (突发承载)
    safe_write "8192" "/proc/sys/net/core/netdev_max_backlog"
    safe_write "8192" "/proc/sys/net/ipv4/tcp_max_syn_backlog"
    safe_write "4096" "/proc/sys/net/core/somaxconn"

    # Keepalive (防空闲断开)
    sysctl -w net.ipv4.tcp_keepalive_time=600 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_intvl=30 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_probes=5 >/dev/null 2>&1

    # MTU 探测 (配合 PPPoE + MSS clamp)
    sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1

    # TIME_WAIT 回收
    sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_fin_timeout=15 >/dev/null 2>&1

    # 高并发代理: 扩本地端口范围 / TIME_WAIT 上限 / 关空闲慢启动
    sysctl -w net.ipv4.ip_local_port_range="10240 65535" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_max_tw_buckets=65536 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1

    # TCP 输出限制 (改善多流公平, 降抖动)
    sysctl -w net.ipv4.tcp_limit_output_bytes=131072 >/dev/null 2>&1

    echo "  [TCP] Applied buffer and connection tuning."

    # Part 5: Conntrack (代理高并发)
    if [ -d "/proc/sys/net/netfilter" ]; then
        safe_write "262144" "/proc/sys/net/netfilter/nf_conntrack_max"

        # established=86400: 表容量充足时避免 1h 误杀空闲长连接 (SSH/IMAP IDLE/DB keepalive)
        safe_write "86400" "/proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established"
        safe_write "60" "/proc/sys/net/netfilter/nf_conntrack_tcp_timeout_close_wait"
        safe_write "30" "/proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait"
        safe_write "30" "/proc/sys/net/netfilter/nf_conntrack_udp_timeout"
        safe_write "120" "/proc/sys/net/netfilter/nf_conntrack_udp_timeout_stream"

        echo "  [Conntrack] Applied timeout tuning for proxy workload."
    fi

    # fd 限制: init shell 的 ulimit 对 mihomo 无效, 改设 nikki procd rlimit_nofile (下次 nikki 重启生效)
    if have_cmd uci && uci -q get nikki.procd >/dev/null 2>&1; then
        FD_WANT=524288
        if [ "$(uci -q get nikki.procd.rlimit_nofile_hard)" != "$FD_WANT" ]; then
            uci set nikki.procd.rlimit_nofile_soft="$FD_WANT"
            uci set nikki.procd.rlimit_nofile_hard="$FD_WANT"
            uci commit nikki
            echo "  [Limits] Set nikki procd rlimit_nofile=$FD_WANT (applies on next nikki restart)"
        fi
    fi

    # Part 5.5: ARP/邻居表 (大 LAN, 50+ 设备)
    sysctl -w net.ipv4.neigh.default.gc_thresh1=1024 >/dev/null 2>&1
    sysctl -w net.ipv4.neigh.default.gc_thresh2=2048 >/dev/null 2>&1
    sysctl -w net.ipv4.neigh.default.gc_thresh3=4096 >/dev/null 2>&1
    sysctl -w net.ipv6.neigh.default.gc_thresh1=1024 >/dev/null 2>&1
    sysctl -w net.ipv6.neigh.default.gc_thresh2=2048 >/dev/null 2>&1
    sysctl -w net.ipv6.neigh.default.gc_thresh3=4096 >/dev/null 2>&1
    echo "  [ARP] Applied neighbor cache optimization."

    # Part 5.55: VM/内存 (路由器内存充足, 降 swappiness)
    sysctl -w vm.swappiness=10 >/dev/null 2>&1
    echo "  [VM] Applied memory optimization (swappiness=10)."

    # Part 5.6: IPv6
    if [ -d "/proc/sys/net/ipv6" ]; then
        safe_write "1" "/proc/sys/net/ipv6/conf/all/forwarding"
        # 仅在 WAN 接受 RA (accept_ra=2, for DHCPv6-PD), 避免 LAN 侧风险
        if [ -n "$WAN_PHYS" ] && [ -f "/proc/sys/net/ipv6/conf/$WAN_PHYS/accept_ra" ]; then
            safe_write "2" "/proc/sys/net/ipv6/conf/$WAN_PHYS/accept_ra"
            echo "  [IPv6] Set accept_ra=2 on $WAN_PHYS for DHCPv6-PD."
        fi
        if [ -n "$PPPOE_DEV" ] && [ -f "/proc/sys/net/ipv6/conf/$PPPOE_DEV/accept_ra" ]; then
            safe_write "2" "/proc/sys/net/ipv6/conf/$PPPOE_DEV/accept_ra"
            echo "  [IPv6] Set accept_ra=2 on $PPPOE_DEV."
        fi
        safe_write "3" "/proc/sys/net/ipv6/conf/default/router_solicitations"
        echo "  [IPv6] Applied forwarding optimization."
    fi

    # Part 6: SQM (1Gbps + PPPoE + 低延迟)
    if [ ! -f /etc/config/sqm ]; then
        echo "  [SQM] Warning: /etc/config/sqm not found. Install sqm-scripts package first:"
        echo "        opkg update && opkg install sqm-scripts luci-app-sqm"
    elif [ -z "$PPPOE_DEV" ]; then
        echo "  [SQM] Skipped: PPPoE interface not detected"
    else
        SQM_NEED_COMMIT=0
        SQM_SECTION="wan"

        # 仅清理接口已不存在的残留节，保留其他接口上的 SQM 配置。
        for section in $(uci show sqm 2>/dev/null | grep '=queue$' | cut -d'.' -f2 | cut -d'=' -f1); do
            section_if="$(uci get sqm.$section.interface 2>/dev/null)"
            [ -z "$section_if" ] && continue
            [ "$section_if" = "$PPPOE_DEV" ] && continue
            if [ ! -d "/sys/class/net/$section_if" ]; then
                uci delete sqm."$section" 2>/dev/null
                SQM_NEED_COMMIT=1
                echo "  [SQM] Removed stale config sqm.$section (interface $section_if not found)"
            fi
        done

        # 查找已有的 PPPoE 配置节
        EXISTING_SECTION=""
        for section in $(uci show sqm 2>/dev/null | grep '=queue$' | cut -d'.' -f2 | cut -d'=' -f1); do
            section_if="$(uci get sqm.$section.interface 2>/dev/null)"
            if [ "$section_if" = "$PPPOE_DEV" ]; then
                EXISTING_SECTION="$section"
                break
            fi
        done

        if [ -n "$EXISTING_SECTION" ]; then
            SQM_SECTION="$EXISTING_SECTION"
            echo "  [SQM] Found existing config for $PPPOE_DEV (sqm.$SQM_SECTION)"
        else
            # 无正确配置时才新建，保留其他接口的配置。
            echo "  [SQM] Creating new config section for $PPPOE_DEV"
            uci set sqm.$SQM_SECTION=queue
            SQM_NEED_COMMIT=1
        fi

        uci set sqm.$SQM_SECTION.interface="$PPPOE_DEV"
        uci set sqm.$SQM_SECTION.qdisc="cake"
        uci set sqm.$SQM_SECTION.script="layer_cake.qos"
        # 新配置默认下载 1000M、上传 50M；保留用户之后的带宽调整。
        [ -n "$(uci -q get sqm.$SQM_SECTION.download)" ] || uci set sqm.$SQM_SECTION.download="1000000"
        [ -n "$(uci -q get sqm.$SQM_SECTION.upload)" ] || uci set sqm.$SQM_SECTION.upload="50000"
        # CAKE 直接使用总开销：以太网 38B + PPPoE/PPP 8B；VLAN 再加 4B。
        SQM_OVERHEAD=46
        case "$WAN_DEV" in
            *.*) SQM_OVERHEAD=50 ;;
        esac
        uci set sqm.$SQM_SECTION.linklayer="ethernet"
        uci set sqm.$SQM_SECTION.overhead="$SQM_OVERHEAD"
        uci set sqm.$SQM_SECTION.tcMPU="84"
        uci set sqm.$SQM_SECTION.enabled="1"
        uci set sqm.$SQM_SECTION.debug_logging="0"
        uci set sqm.$SQM_SECTION.verbosity="5"
        # egress: nat/dual-srchost 每主机公平, wash 清 DSCP, ack-filter 省非对称上行 ACK
        # ingress: dual-dsthost 每主机公平；layer_cake 默认补充 nat/wash。
        uci set sqm.$SQM_SECTION.eqdisc_opts="nat dual-srchost wash ack-filter"
        uci set sqm.$SQM_SECTION.iqdisc_opts="dual-dsthost ingress"
        SQM_NEED_COMMIT=1

        if [ "$SQM_NEED_COMMIT" -eq 1 ]; then
            uci commit sqm
            if [ -x /etc/init.d/sqm ]; then
                /etc/init.d/sqm enable 2>/dev/null
                /etc/init.d/sqm restart 2>/dev/null
            fi
            echo "  [SQM] Applied CAKE on $PPPOE_DEV (down=$(uci -q get sqm.$SQM_SECTION.download)kbit/up=$(uci -q get sqm.$SQM_SECTION.upload)kbit, overhead=$SQM_OVERHEAD, mpu=84)"
        fi

        sleep 1
        if tc qdisc show dev "$PPPOE_DEV" 2>/dev/null | grep -q cake; then
            echo "  [SQM] CAKE qdisc active on $PPPOE_DEV"
        else
            echo "  [SQM] Warning: CAKE not detected on $PPPOE_DEV, check logs"
        fi
    fi

    # Part 7: 状态报告
    echo ""
    echo "  === Configuration Summary ==="
    echo "  WAN Physical: ${WAN_PHYS:-N/A}"
    echo "  PPPoE Device: ${PPPOE_DEV:-N/A}"
    echo "  TUN Device:   ${TUN_DEV:-N/A} (mtu=$TUN_MTU)"
    echo "  CPU Mask:     $CPU_MASK (4 cores)"
    echo "  Qdisc:        $DEFAULT_QDISC"
    echo "  Port Range:   10240-65535"
    echo ""
    echo "Network Turbo Optimization (v5.9) Applied Successfully."
}
EOF

chmod +x "$DESTDIR/etc/init.d/net_turbo"

echo "=============================================="
echo "  Network Turbo Optimization Script v5.9"
echo "  Target: ImmortalWrt 25.12 + Intel N100"
echo "=============================================="


# Hotplug: TUN/PPPoE/VPN 接口出现时配置 RPS
HOTPLUG_SCRIPT="$DESTDIR/etc/hotplug.d/net/99-net-turbo-rps"
cat << 'HOTPLUG' > "$HOTPLUG_SCRIPT"
#!/bin/sh
# Network Turbo RPS hotplug: configure RPS on TUN/PPPoE/VPN interface add

[ "$ACTION" = "add" ] || exit 0

CPU_MASK="f"  # 4 cores
TUN_MTU=1460  # keep in sync with net_turbo Part 3

case "$INTERFACE" in
    utun|tun0|tun1|pppoe-*|ppp[0-9]*|tailscale0|wg0)
        sleep 1
        for rps_file in /sys/class/net/"$INTERFACE"/queues/rx-*/rps_cpus; do
            [ -w "$rps_file" ] && echo "$CPU_MASK" > "$rps_file" 2>/dev/null
        done
        for rps_flow in /sys/class/net/"$INTERFACE"/queues/rx-*/rps_flow_cnt; do
            [ -w "$rps_flow" ] && echo "4096" > "$rps_flow" 2>/dev/null
        done
        case "$INTERFACE" in
            utun|tun0|tun1)
                ip link set "$INTERFACE" mtu "$TUN_MTU" 2>/dev/null
                ;;
        esac
        logger -t net-turbo "RPS configured for $INTERFACE"
        ;;
esac
HOTPLUG
chmod +x "$HOTPLUG_SCRIPT"
echo "[Setup] Created hotplug script for dynamic TUN/PPPoE/VPN RPS"

if [ -n "$DESTDIR" ]; then
    mkdir -p "$DESTDIR/etc/rc.d" || exit 1
    ln -sf ../init.d/net_turbo "$DESTDIR/etc/rc.d/S99net_turbo" || exit 1
    echo "[Build] Installed Network Turbo files in $DESTDIR"
    exit 0
fi

setup_conntrack_module
setup_irqbalance
/etc/init.d/net_turbo enable
/etc/init.d/net_turbo restart

echo ""
echo "=============================================="
echo "  Optimization Complete!"
echo "  - Service: /etc/init.d/net_turbo"
echo "  - Auto-start: Enabled (rc.d)"
echo "  - Conntrack hashsize: Effective after reboot"
echo "  - Packet Steering: Applied without restarting network"
echo "=============================================="

echo ""
echo "Verification commands:"
echo "  tc qdisc show dev pppoe-wan                     # Check SQM CAKE"
echo "  uci show sqm                                    # Check SQM config"
echo "  cat /sys/class/net/utun/queues/rx-0/rps_cpus   # Check RPS (expect 'f')"
echo "  cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor  # Check CPU governor"
echo "  sysctl net.ipv4.tcp_congestion_control         # Check BBR"
echo "  sysctl net.ipv4.tcp_fastopen                   # Check TFO (expect '3')"
echo ""
echo "Performance test:"
echo "  # Run from LAN client:"
echo "  # speedtest-cli --simple"
echo "  # iperf3 -c <router-ip> -t 30"
echo ""
echo "Tradeoffs to be aware of:"
echo "  - rp_filter=0: Required for TProxy, but reduces anti-spoofing"
echo "  - CPU governor=powersave + EPP=balance_performance: HWP hardware-adaptive scaling (700MHz idle <-> 3.4GHz under load)"
echo ""
