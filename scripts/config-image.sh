#!/bin/bash

set -eE 
set -m
set -o monitor

CHROOT_CHILD_PID=""

trap '
    msg="\n[紧急清理] 收到中断信号！立即停止所有操作并清理挂载点..."
    echo -e "$msg" >&2
    printf "%s\n" "$msg" >/dev/tty 2>/dev/null || true
    if [ -n "$CHROOT_CHILD_PID" ]; then
        kill -INT "$CHROOT_CHILD_PID" 2>/dev/null || true
        wait "$CHROOT_CHILD_PID" 2>/dev/null || true
        CHROOT_CHILD_PID=""
    fi
    sync
    teardown_mountpoint rootfs
    exit 1
' INT TERM HUP QUIT

trap 'teardown_mountpoint rootfs' EXIT

SCRIPT_DIR=$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
ORIGINAL_PWD="$PWD"

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root" >&2
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..

mkdir -p build && cd build

if [[ -z ${BOARD} ]]; then
    echo "Error: BOARD is not set" >&2
    exit 1
fi

source "../config/boards/${BOARD}.sh"

if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set" >&2
    exit 1
fi

source "../config/suites/${SUITE}.sh"

if [[ -z ${FLAVOR} ]]; then
    echo "Error: FLAVOR is not set" >&2
    exit 1
fi

source "../config/flavors/${FLAVOR}.sh"

if [[ ${LAUNCHPAD} != "Y" ]]; then
    uboot_package="$(basename "$(find u-boot-"${BOARD}"_*.deb | sort | tail -n1)")"
    if [ ! -e "$uboot_package" ]; then
        echo 'Error: could not find the u-boot package' >&2
        exit 1
    fi

    kernel_debs=()
    for pattern in "linux-image-*.deb" "linux-headers-*.deb" "linux-modules-*.deb" "linux-buildinfo-*.deb" "linux-rockchip-headers-*.deb"; do
        deb_file="$(basename "$(find $pattern | sort | tail -n1)")"
        if [ ! -e "$deb_file" ]; then
            echo "Error: could not find $pattern" >&2
            exit 1
        fi
        kernel_debs+=("$deb_file")
    done
fi

chroot() {
    command chroot "$@" &
    command chroot "$@" &
    local pid=$!
    CHROOT_CHILD_PID=$pid

    wait "$pid" 2>/dev/null
    local ret=$?

    CHROOT_CHILD_PID=""

    if [ $ret -ge 128 ]; then
        echo "[chroot] 子进程被信号中断（PID: $pid）" >&2
    fi
    return $ret
}
export -f chroot

setup_mountpoint() {
    local mountpoint="$1"
    if [ ! -c /dev/mem ]; then
        mknod -m 660 /dev/mem c 1 1
        chown root:kmem /dev/mem
    fi
    mount dev-live -t devtmpfs "$mountpoint/dev"
    mount devpts-live -t devpts -o nodev,nosuid "$mountpoint/dev/pts"
    mount proc-live -t proc "$mountpoint/proc"
    mount sysfs-live -t sysfs "$mountpoint/sys"
    mount securityfs -t securityfs "$mountpoint/sys/kernel/security"
    mount -t cgroup2 none "$mountpoint/sys/fs/cgroup"
    mount -t tmpfs -o size=15G none "$mountpoint/tmp"
    mount -t tmpfs none "$mountpoint/var/lib/apt/lists"
    mount -t tmpfs none "$mountpoint/var/cache/apt"
    mv "$mountpoint/etc/resolv.conf" resolv.conf.tmp
    cp /etc/resolv.conf "$mountpoint/etc/resolv.conf"
    mv "$mountpoint/etc/nsswitch.conf" nsswitch.conf.tmp
    sed 's/systemd//g' nsswitch.conf.tmp > "$mountpoint/etc/nsswitch.conf"
}

teardown_mountpoint() {
    local mountpoint="$1"
    set +e
    cd "$ORIGINAL_PWD" && cd build
    if [ -n "$mountpoint" ] && [ -d "$mountpoint" ]; then
        awk -v mp="$mountpoint" '$2 ~ "^"mp { print $2 }' /proc/self/mounts | sort -r | xargs -r umount -l
        [ -f resolv.conf.tmp ] && mv -f resolv.conf.tmp "$mountpoint/etc/resolv.conf"
        [ -f nsswitch.conf.tmp ] && mv -f nsswitch.conf.tmp "$mountpoint/etc/nsswitch.conf"
    fi
    set -e
}

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

chroot_dir=rootfs
overlay_dir=../overlay

rm -rf ${chroot_dir} && mkdir -p ${chroot_dir}
tar -xpI 'xz -d -T0' -f "ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz" -C ${chroot_dir}

setup_mountpoint $chroot_dir

type configure_apt_sources &> /dev/null && "$_" "$chroot_dir" "${SUITE}"

chroot $chroot_dir apt-get update
chroot $chroot_dir apt-get -y upgrade

if [[ ${LAUNCHPAD} == "Y" ]]; then
    chroot ${chroot_dir} apt-get -y install "u-boot-${BOARD}"
else
    mkdir -p ${chroot_dir}/tmp

    if [ -f "./${uboot_package}" ]; then
        base_name=$(echo "$uboot_package" | sed 's/_.*//')
        cp "./${uboot_package}" "${chroot_dir}/tmp/${base_name}.deb"
        chroot "${chroot_dir}" dpkg -i "/tmp/${base_name}.deb" || (
            chroot "${chroot_dir}" apt-get -fy install && chroot "${chroot_dir}" dpkg -i "/tmp/${base_name}.deb"
        )
        chroot "${chroot_dir}" apt-mark hold "${base_name}"
    else
        echo "Error: missing deb file ${uboot_package}" >&2
        ls -lh
        exit 1
    fi

    for deb in "${kernel_debs[@]}"; do
        if [ ! -f "./$deb" ]; then
            echo "Error: missing deb file $deb" >&2
            ls -lh
            exit 1
        fi
        base_name=$(echo "$deb" | sed 's/_.*//')
        cp "./$deb" "${chroot_dir}/tmp/${base_name}.deb"
    done

    ls -lh "${chroot_dir}/tmp/"

    deb_files=""
    header_deb=""
    for deb in "${kernel_debs[@]}"; do
        base_name=$(echo "$deb" | sed 's/_.*//')
        deb_files+="/tmp/${base_name}.deb "
        case "$base_name" in
            linux-rockchip-headers*|linux-headers-*)
                header_deb="/tmp/${base_name}.deb"
                ;;
        esac
    done

    if [ -n "${header_deb}" ]; then
        echo "Installing kernel headers first: ${header_deb}" >&2
        chroot "${chroot_dir}" /bin/bash -lc "set -e; dpkg -i ${header_deb} 2>/tmp/dpkg_headers_install.log || true; apt-get update -y; apt-get -f install -y"
    fi

    echo "Installing kernel packages: ${deb_files}" >&2
    chroot "${chroot_dir}" /bin/bash -lc "set -e; dpkg -i ${deb_files} 2>/tmp/dpkg_kern_install.log || apt-get -fy install -y"

    chroot "${chroot_dir}" /bin/bash -lc '
set -e
HDRDIR="$(ls -d /usr/src/linux-headers-6.1.* 2>/dev/null | head -n1 || true)"
if [ -z "$HDRDIR" ]; then
  HDRDIR="$(ls -d /usr/src/linux-headers-* 2>/dev/null | head -n1 || true)"
fi
if [ -z "$HDRDIR" ]; then
  echo "WARN: HDRDIR not found; ensure matching linux-headers package is installed" >&2
  exit 0
fi
ver="$(basename "$HDRDIR" | sed "s/^linux-headers-//")"
mkdir -p "/lib/modules/$ver"
ln -sf "$HDRDIR" "/lib/modules/$ver/build"
echo "INFO: linked /lib/modules/$ver/build -> $HDRDIR" >&2
apt-get update -y || true
apt-get install -y --no-install-recommends \
  build-essential make bc dkms libncurses-dev libelf-dev perl python3 \
  flex bison || true
if ! command -v flex >/dev/null 2>&1; then
  echo "ERROR: flex not found after install" >&2
  exit 1
fi
if ! command -v bison >/dev/null 2>&1; then
  echo "ERROR: bison not found after install" >&2
  exit 1
fi
if [ -f "$HDRDIR/Makefile" ]; then
  echo "INFO: running make modules_prepare in $HDRDIR" >&2
  (cd "$HDRDIR" && make modules_prepare) || {
    echo "ERROR: make modules_prepare failed in $HDRDIR" >&2
    exit 1
  }
else
  echo "WARN: $HDRDIR/Makefile not found" >&2
fi
if [ -f "$HDRDIR/include/generated/utsrelease.h" ] || [ -f "/lib/modules/$ver/build/Makefile" ]; then
  echo "INFO: headers appear prepared for $ver" >&2
else
  echo "WARN: headers may be incomplete for $ver" >&2
  ls -la "$HDRDIR" || true
  ls -la "/lib/modules/$ver" || true
fi
'

    for deb in "${kernel_debs[@]}"; do
        base_name=$(echo "$deb" | sed 's/_.*//')
        chroot "${chroot_dir}" apt-mark hold "${base_name}" || true
    done
fi

if [[ -z "${TARGET_KERNEL_VERSION}" ]]; then
    target_kernel_version=$(chroot "${chroot_dir}" bash -c "ls /lib/modules | grep rockchip | sort -V | tail -n1" || true)
    if [[ -n "${target_kernel_version}" ]]; then
        export TARGET_KERNEL_VERSION="${target_kernel_version}"
    fi
fi

if [[ $(type -t config_image_hook__"${BOARD}") == function ]]; then
    config_image_hook__"${BOARD}" "${chroot_dir}" "${overlay_dir}" "${SUITE}"
fi

chroot ${chroot_dir} update-initramfs -u
chroot ${chroot_dir} apt-get -y clean
chroot ${chroot_dir} apt-get -y autoclean
chroot ${chroot_dir} apt-get -y autoremove

trap - EXIT INT TERM HUP QUIT
teardown_mountpoint $chroot_dir

cd ${chroot_dir} && tar --warning=no-file-changed -cpf "../ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar" . && cd .. && rm -rf ${chroot_dir}
../scripts/build-image.sh "ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"
rm -f "ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"