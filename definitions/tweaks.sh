#!/bin/bash
set -x

:<< "NOTES"
{
echo "--- Environment Check ---"
mount -l | grep "chroot" || echo "No specific chroot mounts detected."

# 2. 检查 /dev/null 的状态
# [ -c /dev/null ] 检查它是否为字符设备
if [ -c /dev/null ]; then
    echo "✅ /dev/null is a valid character device. Skipping hack."
else
    echo "⚠️ /dev/null is missing or invalid. Applying hack..."
    # 只有在它不是正常字符设备时才执行 hack
    rm -f /dev/null
    touch /dev/null
    chmod 666 /dev/null
    echo "✅ /dev/null hacked as a regular file for apt compatibility."
fi
}
NOTES

{
mkdir -p /proc /sys /dev/pts || true
mount -t proc proc /proc || true
mount -t sysfs sysfs /sys || true
mount -t devpts devpts /dev/pts || true

# 2. 绕过 /dev/null 权限问题 (既然 mknod 不行)
if [ ! -c /dev/null ]; then
    echo "⚠️ /dev/null 不是设备文件，执行兼容性 Hack..."
    rm -f /dev/null
    touch /dev/null
    chmod 666 /dev/null
fi
}

# Fix environment and permissions
{
    #rm -f /dev/null
    #mknod -m 666 /dev/null c 1 3
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
    apt-get update
    apt-get install -y --no-install-recommends gnupg2 dirmngr ca-certificates software-properties-common
    apt-get purge -y firefox || true
    add-apt-repository ppa:mozillateam/ppa -y
    cat << 'EOF' > /etc/apt/preferences.d/mozillateam
Package: firefox*
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
EOF
    apt-get update
    apt-get policy firefox
    apt-get install -y firefox
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
umount -l /proc || true
umount -l /sys || true
umount -l /dev/pts || true
}

set +x
rm -- "$0"
