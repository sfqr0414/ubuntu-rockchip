#!/bin/bash

host_call() {
    local cmd="$1"
    local ignore_err="${2:-false}"
    echo "$cmd" > /.cmd_fifo
    
    while [ ! -f "/.cmd_ack" ]; do sleep 0.1; done
    local status=$(cat /.cmd_ack)
    rm -f "/.cmd_ack"
    
    if [ "$status" -ne 0 ]; then
        if [ "$ignore_err" = "true" ]; then
            echo "⚠️ Command failed but proceeding: $cmd"
        else
            echo "❌ Fatal error ($status) executing host command: $cmd"
            exit 1
        fi
    fi
}

{
    # use host privileges to add missing devices and mounts
    host_call "mkdir -p /proc /sys /dev/pts"
    host_call "mount -t proc proc /proc"
    host_call "mount -t sysfs sysfs /sys"
    host_call "mount -t devpts devpts /dev/pts"

    # host can create the real /dev/null device
    host_call "rm -f /dev/null && mknod -m 666 /dev/null c 1 3"
}

{
    echo -e "-------- mount nodes -----------\n"
    mount -l
}

# Fix environment and permissions
{
    host_call "rm -rf /etc/resolv.conf"
    host_call 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'
}

# Boot and Kernel configurations
{
    pro config set apt_news=false || true
    mkdir -p /usr/share/u-boot-menu/conf.d
    cat << 'EOF' > /usr/share/u-boot-menu/conf.d/ubuntu.conf
U_BOOT_PROMPT="1"
U_BOOT_PARAMETERS="$(cat /etc/kernel/cmdline)"
U_BOOT_TIMEOUT="20"
EOF
    echo -n "rootwait rw console=ttyS2,1500000 console=tty1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory" > /etc/kernel/cmdline
}

# Install Firefox via PPA (No Snap)
{
    apt update
    apt install -y --no-install-recommends gnupg2 dirmngr ca-certificates software-properties-common
    apt purge -y firefox || true
    add-apt-repository ppa:mozillateam/ppa -y
    cat << 'EOF' > /etc/apt/preferences.d/mozillateam
Package: firefox*
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001

Package: firefox*
Pin: release o=Ubuntu
Pin-Priority: -1
EOF
    apt update
    apt policy firefox
    apt install -y firefox
}

# NetworkManager policy routing
{
    mkdir -p /etc/NetworkManager/dispatcher.d/
    cat << 'EOF' > /etc/NetworkManager/dispatcher.d/99-policy-routing
#!/bin/bash
# /etc/NetworkManager/dispatcher.d/99-policy-routing
# 基于 fwmark 的策略路由脚本（生产级：并发安全 + 环形日志版）

set -u
IFACE="$1"
ACTION="$2"

# ========== 1. 并发排队锁（防止 NM 密集事件冲突互踩）==========
LOCK_FILE="/var/lock/policy-routing.lock"
exec 9>"$LOCK_FILE"
# 等待最多 5 秒获取锁，排队执行，超时则安全退出
if ! flock -w 5 9; then
    exit 0
fi

# ========== 2. 日志环形缓冲区配置 ==========
LOG_FILE="/var/log/policy-routing.log"
MAX_LOG_SIZE_MB=50

truncate_old_logs() {
    local max_size_bytes=$((MAX_LOG_SIZE_MB * 1024 * 1024))
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)

    if [ "$size" -ge "$max_size_bytes" ]; then
        local temp_file="${LOG_FILE}.tmp"
        if tail -n 250000 "$LOG_FILE" > "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$LOG_FILE"
            chmod 644 "$LOG_FILE" 2>/dev/null || true
            echo "--- [System: Oldest log messages discarded to maintain ${MAX_LOG_SIZE_MB}MB limit] ---" >> "$LOG_FILE"
        else
            rm -f "$temp_file"
        fi
    fi
}

log() {
    truncate_old_logs
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$IFACE-$ACTION] $*" >> "$LOG_FILE"
}

get_table_mark() {
    if [ "$IFACE" = "lo" ]; then
        exit 0
    fi

    if [ -d "/sys/class/net/$IFACE/wireless" ] || [ -d "/sys/class/net/$IFACE/phy80211" ]; then
        TYPE="wifi"
        TABLE=200
        MARK=200
        PRIO=30001
    elif [ -d "/sys/class/net/$IFACE" ]; then
        TYPE="ethernet"
        TABLE=100
        MARK=100
        PRIO=30000
    else
        log "Unknown or unsupported interface type, exit"
        exit 0
    fi
}

# 安全删除 iptables 规则函数
safe_iptables_delete() {
    local table="$1"
    local chain="$2"
    shift 2
    while iptables -t "$table" -D "$chain" "$@" 2>/dev/null; do :; done
    while ip6tables -t "$table" -D "$chain" "$@" 2>/dev/null; do :; done
}

# 添加 iptables 规则（含连接跟踪）
add_iptables_rules() {
    log "Adding iptables rules for $IFACE (mark $MARK)"

    iptables -t mangle -A PREROUTING -i "$IFACE" -j CONNMARK --set-mark "$MARK" || true
    ip6tables -t mangle -A PREROUTING -i "$IFACE" -j CONNMARK --set-mark "$MARK" || true

    iptables -t mangle -A OUTPUT -m connmark --mark "$MARK" -j CONNMARK --restore-mark || true
    ip6tables -t mangle -A OUTPUT -m connmark --mark "$MARK" -j CONNMARK --restore-mark || true

    iptables -t mangle -A OUTPUT -o "$IFACE" -m mark --mark 0 -j MARK --set-mark "$MARK" || true
    iptables -t mangle -A OUTPUT -o "$IFACE" -j CONNMARK --save-mark || true

    ip6tables -t mangle -A OUTPUT -o "$IFACE" -m mark --mark 0 -j MARK --set-mark "$MARK" || true
    ip6tables -t mangle -A OUTPUT -o "$IFACE" -j CONNMARK --save-mark || true

    log "Added IPv4 & IPv6 mark and connmark rules"
}

# 删除 iptables 规则
delete_iptables_rules() {
    log "Deleting iptables rules for $IFACE (mark $MARK)"
    safe_iptables_delete mangle PREROUTING -i "$IFACE" -j CONNMARK --set-mark "$MARK"
    safe_iptables_delete mangle OUTPUT -m connmark --mark "$MARK" -j CONNMARK --restore-mark
    safe_iptables_delete mangle OUTPUT -o "$IFACE" -m mark --mark 0 -j MARK --set-mark "$MARK"
    safe_iptables_delete mangle OUTPUT -o "$IFACE" -j CONNMARK --save-mark
    log "Deleted iptables rules"
}

# 添加策略路由规则
add_policy_rules() {
    log "Adding policy rules for mark $MARK -> table $TABLE (prio $PRIO)"
    ip rule del fwmark "$MARK" priority "$PRIO" 2>/dev/null || true
    ip -6 rule del fwmark "$MARK" priority "$PRIO" 2>/dev/null || true

    ip rule add fwmark "$MARK" lookup "$TABLE" priority "$PRIO" || true
    ip -6 rule add fwmark "$MARK" lookup "$TABLE" priority "$PRIO" || true
    log "Added policy rules"
}

# 删除策略路由规则
delete_policy_rules() {
    log "Deleting policy rules for mark $MARK (prio $PRIO)"
    ip rule del fwmark "$MARK" priority "$PRIO" 2>/dev/null && log "Deleted IPv4 policy rule" || log "IPv4 policy rule not found"
    ip -6 rule del fwmark "$MARK" priority "$PRIO" 2>/dev/null && log "Deleted IPv6 policy rule" || log "IPv6 policy rule not found"
}

# 解析接口和路由信息（标准网络前缀提取）
get_ip_info() {
    gw4=""
    subnet4=""
    gw6=""
    subnet6=""

    # --- IPv4 网关：优先取环境变量第二段，保底从内核默认路由取 ---
    if [ -n "${IP4_ADDRESS_0:-}" ]; then
        gw4=$(echo "$IP4_ADDRESS_0" | awk '{print $2}')
    fi
    if [ -z "$gw4" ]; then
        gw4=$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}' || true)
    fi

    # --- IPv4 子网：从内核直连链路路由中抓取规范网络号（主机位全 0）---
    subnet4=$(ip -4 route show dev "$IFACE" scope link 2>/dev/null | awk '{print $1; exit}' || true)

    # --- IPv6 网关：优先取环境变量第二段，保底从内核默认路由取 ---
    if [ -n "${IP6_ADDRESS_0:-}" ]; then
        gw6=$(echo "$IP6_ADDRESS_0" | awk '{print $2}')
    fi
    if [ -z "$gw6" ]; then
        gw6=$(ip -6 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}' || true)
    fi

    # --- IPv6 子网：明确只抓取 ::/64 直连网段，排除 /128 单机地址 ---
    subnet6=$(ip -6 route show dev "$IFACE" 2>/dev/null \
        | awk '!/default/ && !/fe80/ && /::\/64/ {print $1; exit}' || true)
}

# 配置专用路由表
add_routes() {
    get_ip_info
    log "Adding routes to table $TABLE (gw4='$gw4' subnet4='$subnet4' gw6='$gw6' subnet6='$subnet6')"

    # 配置 IPv4
    if [ -n "$subnet4" ]; then
        ip route replace "$subnet4" dev "$IFACE" scope link table "$TABLE" || true
        log "IPv4 link route added: $subnet4"
    fi
    if [ -n "$gw4" ]; then
        ip route replace default via "$gw4" dev "$IFACE" table "$TABLE" || true
        log "IPv4 default route added via $gw4"
    fi

    # 配置 IPv6（显式添加 scope link）
    if [ -n "$subnet6" ]; then
        ip -6 route replace "$subnet6" dev "$IFACE" scope link table "$TABLE" || true
        log "IPv6 link route added: $subnet6"
    fi
    if [ -n "$gw6" ]; then
        ip -6 route replace default via "$gw6" dev "$IFACE" table "$TABLE" || true
        log "IPv6 default route added via $gw6"
    fi
}

flush_routes() {
    log "Flushing table $TABLE"
    ip route flush table "$TABLE" 2>/dev/null || true
    ip -6 route flush table "$TABLE" 2>/dev/null || true
    log "Flushed table $TABLE"
}

# ========== 主逻辑 ==========
if [ "$IFACE" = "lo" ]; then
    exit 0
fi

case "$ACTION" in
    up|dhcp4-change|dhcp6-change)
        ACTION_INTERNAL="up"
        ;;
    down)
        ACTION_INTERNAL="down"
        ;;
    *)
        exit 0
        ;;
esac

log "========== START action=$ACTION (processed as $ACTION_INTERNAL) =========="
get_table_mark

if [ "$ACTION_INTERNAL" = "up" ]; then
    delete_iptables_rules
    delete_policy_rules
    flush_routes

    add_iptables_rules
    add_policy_rules
    add_routes
    log "UP completed"
elif [ "$ACTION_INTERNAL" = "down" ]; then
    delete_iptables_rules
    delete_policy_rules
    flush_routes
    log "DOWN completed"
fi

exit 0
EOF
    chmod +x /etc/NetworkManager/dispatcher.d/99-policy-routing
}

# Cleanup and Image finalization
{
    apt-get autoremove -y
    apt-get clean -y
    apt-get autoclean -y
    update-initramfs -u
    u-boot-update
}

{
    # unmount now or ubuntu-image copy will fail
    host_call "umount -l /dev/pts || true"
    host_call "umount -l /sys || true"
    host_call "umount -l /proc || true"
    # delete the temporary /dev/null device
    host_call "rm -f /dev/null"
}

{
    echo "TERMINATE" > /.cmd_fifo
}

rm -- "$0"
