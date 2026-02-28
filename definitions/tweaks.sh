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

# Clean package cache
apt-get autoremove --assume-yes
apt-get clean --assume-yes
apt-get autoclean --assume-yes

# Make sure the initramfs is up to date
update-initramfs -u

# Update extlinux
u-boot-update

rm -- "$0"
