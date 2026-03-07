#!/bin/bash

rm -rf /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
pro config set apt_news=false

# Override u-boot-menu config  
mkdir -p /usr/share/u-boot-menu/conf.d
cat << 'EOF' > /usr/share/u-boot-menu/conf.d/ubuntu.conf
U_BOOT_PROMPT="1"
U_BOOT_PARAMETERS="$(cat /etc/kernel/cmdline)"
U_BOOT_TIMEOUT="20"
EOF

# Default kernel command line arguments
echo -n "rootwait rw console=ttyS2,1500000 console=tty1 cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory" > /etc/kernel/cmdline

{
sudo snap remove firefox || true
sudo add-apt-repository ppa:mozillateam/ppa -y
sudo apt update -y

echo 'Package: firefox*
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 990' | sudo tee /etc/apt/preferences.d/mozillateam

apt policy firefox
sudo apt install firefox -y
} &

{
cat << 'EOF' > /etc/NetworkManager/dispatcher.d/99-policy-routing
#!/bin/bash
IFACE=$1
ACTION=$2

[ "$ACTION" != "up" ] && exit 0

IP4=$(ip -4 addr show "$IFACE" scope global | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
[ -z "$IP4" ] && exit 0

TYPE=$(nmcli -t -f GENERAL.TYPE device show "$IFACE" | cut -d: -f2)
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
ls -l /etc/NetworkManager/dispatcher.d/99-policy-routing
cat /etc/NetworkManager/dispatcher.d/99-policy-routing
chmod +x /etc/NetworkManager/dispatcher.d/99-policy-routing
} &

wait

# Clean package cache
apt-get autoremove --assume-yes
apt-get clean --assume-yes
apt-get autoclean --assume-yes

# Make sure the initramfs is up to date
update-initramfs -u

# Update extlinux
u-boot-update

rm -- "$0"
