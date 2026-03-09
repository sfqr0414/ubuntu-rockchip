#!/bin/bash
set -x

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
    # 利用信使（宿主权限）强行补齐设备节点和挂载
    host_call "mkdir -p /proc /sys /dev/pts"
    host_call "mount -t proc proc /proc"
    host_call "mount -t sysfs sysfs /sys"
    host_call "mount -t devpts devpts /dev/pts"

    # 这一步是赢的核心：宿主有权创建真正的字符设备
    host_call "rm -f /dev/null && mknod -m 666 /dev/null c 1 3"
}

{
    echo -e "-------- mount nodes -----------\n"
    mount -l
}

# Fix environment and permissions
{
    rm -rf /etc/resolv.conf
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "127.0.0.1 localhost $(hostname)" > /etc/hosts
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
IFACE=$1
ACTION=$2
[ "$ACTION" != "up" ] && exit 0
IP4=$(ip -4 addr show "$IFACE" scope global | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
[ -z "$IP4" ] && exit 0
TYPE=$(nmcli -t -f GENERAL.TYPE device show "$IFACE" 2>/dev/null | cut -d: -f2)
[ "$TYPE" == "ethernet" ] && { TABLE=100; PRIO=30000; }
[ "$TYPE" == "wifi" ] && { TABLE=200; PRIO=30001; }
[ -z "$TABLE" ] && exit 0
LOCAL_SUBNET=$(ip -4 route show dev "$IFACE" | grep "/" | grep -v "default" | awk '{print $1}' | head -n 1)
if [ -n "$LOCAL_SUBNET" ]; then
    ip rule del to "$LOCAL_SUBNET" lookup main priority 29999 2>/dev/null
    ip rule add to "$LOCAL_SUBNET" lookup main priority 29999
fi
GW4=$(ip -4 route show dev "$IFACE" | awk '/default via / {print $3}' | head -n 1)
if [ -n "$IP4" ] && [ -n "$GW4" ]; then
    ip rule del priority $PRIO 2>/dev/null
    ip rule add from "$IP4" table "$TABLE" priority $PRIO
    ip route replace default via "$GW4" dev "$IFACE" table "$TABLE"
fi
IP6s=$(ip -6 addr show "$IFACE" scope global | awk '/inet6 / {print $2}' | cut -d/ -f1 | grep -v '^fe80')
GW6=$(ip -6 route show dev "$IFACE" | awk '/default via / {print $3}' | head -n 1)
if [ -n "$IP6s" ] && [ -n "$GW6" ]; then
    ip -6 rule del priority $PRIO 2>/dev/null
    for IP6 in $IP6s; do ip -6 rule add from "$IP6" table "$TABLE" priority $PRIO; done
    ip -6 route replace default via "$GW6" dev "$IFACE" table "$TABLE"
fi
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
    # 清理：必须在脚本结束前卸载，否则 ubuntu-image 拷贝会崩溃
    host_call "umount -l /dev/pts || true"
    host_call "umount -l /sys || true"
    host_call "umount -l /proc || true"
    # 别忘了删掉刚建的设备节点，防止拷贝工具报错
    host_call "rm -f /dev/null"
}

{
    # 2. 验证当前状态
    echo "🔍 Tweaks: Verifying APT state before backup..."
    cat /etc/apt/sources.list || true
    ls -l /etc/apt/sources.list.d/ || true
    cat /etc/apt/sources.list.d/* || true

    # 3. 🚨 核心战术：执行物理影子备份
    echo "📦 Backing up APT state to physical shadow directory..."
    host_call "cp -a /etc/apt/* /.apt_shadow_backup/"

    echo -e "\n ------------- List apt_shadow_backup contents... --------------\n"
    host_call "ls -lh /.apt_shadow_backup/"

    host_call "mkdir -p /usr/local/share/apt_safe_harbor/"
    
    # 3. 物理拷贝：把 /etc/apt 整个目录的“此时此刻实相”固化下来
    # 使用 -a (archive) 极其重要，它能保留 PPA 密钥文件的权限和所有权
    backup_path="/usr/local/share/apt_safe_harbor/"
    host_call "cp -a /etc/apt/. ${backup_path}"
    echo -e "\n ------------- List apt_safe_harbor contents... --------------\n"
    host_call "ls -lh ${backup_path}"
    
    # 4. 再次刷盘，确保备份目录也已写入物理扇区
    host_call "sync || true"
}

{
    echo "TERMINATE" > /.cmd_fifo
}
set +x
rm -- "$0"
