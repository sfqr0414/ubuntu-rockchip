#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..

mkdir -p build && cd build

if [[ -z ${BOARD} ]]; then
    echo "Error: BOARD is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/boards/${BOARD}.sh"

if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/suites/${SUITE}.sh"

if [[ -z ${FLAVOR} ]]; then
    echo "Error: FLAVOR is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/flavors/${FLAVOR}.sh"

if [[ ${LAUNCHPAD} != "Y" ]]; then
    uboot_package="$(basename "$(find u-boot-"${BOARD}"_*.deb | sort | tail -n1)")"
    if [ ! -e "$uboot_package" ]; then
        echo 'Error: could not find the u-boot package'
        exit 1
    fi

    kernel_debs=()
    for pattern in "linux-image-*.deb" "linux-headers-*.deb" "linux-modules-*.deb" "linux-buildinfo-*.deb" "linux-rockchip-headers-*.deb"; do
        deb_file="$(basename "$(find $pattern | sort | tail -n1)")"
        if [ ! -e "$deb_file" ]; then
            echo "Error: could not find $pattern"
            exit 1
        fi
        kernel_debs+=("$deb_file")
    done
fi

setup_mountpoint() {
    local mountpoint="$1"
    if [ ! -c /dev/mem ]; then
        mknod -m 660 /dev/mem c 1 1
        chown root:kmem /dev/mem
    fi

    mkdir -p "$mountpoint/dev" "$mountpoint/dev/pts" "$mountpoint/dev/shm" \
             "$mountpoint/proc" "$mountpoint/sys" "$mountpoint/sys/kernel/security" \
             "$mountpoint/sys/fs/cgroup" "$mountpoint/tmp"

    mount dev-live -t devtmpfs "$mountpoint/dev"
    mount devpts-live -t devpts -o nodev,nosuid,noexec,mode=620,ptmxmode=666 "$mountpoint/dev/pts"
    ln -sf /dev/pts/ptmx "$mountpoint/dev/ptmx"
    chmod 666 "$mountpoint/dev/ptmx"

    mount proc-live -t proc "$mountpoint/proc"
    mount sysfs-live -t sysfs "$mountpoint/sys"
    mount securityfs -t securityfs "$mountpoint/sys/kernel/security"
    mount -t cgroup2 none "$mountpoint/sys/fs/cgroup"
    mount -t tmpfs -o size=15G,mode=1777 none "$mountpoint/tmp"
    mount -t tmpfs none "$mountpoint/var/lib/apt/lists"
    mount -t tmpfs none "$mountpoint/var/cache/apt"

    mv "$mountpoint/etc/resolv.conf" resolv.conf.tmp
    cp /etc/resolv.conf "$mountpoint/etc/resolv.conf"
    mv "$mountpoint/etc/nsswitch.conf" nsswitch.conf.tmp
    sed 's/systemd//g' nsswitch.conf.tmp > "$mountpoint/etc/nsswitch.conf"
}

teardown_mountpoint() {
    local mountpoint
    mountpoint=$(realpath "$1")
    mountpoint_match=$(echo "$mountpoint" | sed -e 's,/$,,; s,/,\\/,g')
    awk -v mp="$mountpoint_match" '$2 ~ "^"mp { print $2 }' </proc/self/mounts | LC_ALL=C sort -r | while IFS= read -r submount; do
        mount --make-private "$submount"
        umount "$submount"
    done
    mv resolv.conf.tmp "$mountpoint/etc/resolv.conf"
    mv nsswitch.conf.tmp "$mountpoint/etc/nsswitch.conf"
}

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

chroot_dir=rootfs
overlay_dir=../overlay

rm -rf ${chroot_dir} && mkdir -p ${chroot_dir}
tar -xpI 'xz -d -T0' -f "ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz" -C ${chroot_dir}

setup_mountpoint $chroot_dir

type configure_apt_sources &> /dev/null && "$_" "$chroot_dir" "${SUITE}"
#configure_apt_sources "$chroot_dir" "${SUITE}"

chroot $chroot_dir apt-get update
#chroot $chroot_dir apt-get -y upgrade

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
        echo "Error: missing deb file ${uboot_package}"
        ls -lh
        exit 1
    fi

    for deb in "${kernel_debs[@]}"; do
        if [ ! -f "./$deb" ]; then
            echo "Error: missing deb file $deb"
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
        echo "Installing kernel headers first: ${header_deb}"
        chroot "${chroot_dir}" /bin/bash -lc "set -e; dpkg -i ${header_deb} 2>/tmp/dpkg_headers_install.log || true; apt-get update -y; apt-get -f install -y"
    fi

    echo "Installing kernel packages: ${deb_files}"
    chroot "${chroot_dir}" /bin/bash -lc "set -e; dpkg -i ${deb_files} 2>/tmp/dpkg_kern_install.log || apt-get -fy install -y"

    chroot "${chroot_dir}" /bin/bash -lc '
set -e
ver=$(ls /lib/modules 2>/dev/null | grep rockchip | sort -V | tail -n1 || true)
if [ -n "$ver" ]; then
  hdrdir=""
  hdrdir=$(ls -d /usr/src/*"$ver"* 2>/dev/null | head -n1 || true)
  if [ -z "$hdrdir" ]; then
    short=$(echo "$ver" | sed "s/-[^-]*$//")
    hdrdir=$(ls -d /usr/src/*"$short"* 2>/dev/null | head -n1 || true)
  fi
  if [ -n "$hdrdir" ]; then
    mkdir -p /lib/modules/"$ver"
    ln -sf "$hdrdir" /lib/modules/"$ver"/build
    ln -sf "$hdrdir" /usr/src/linux-headers-"$ver" 2>/dev/null || true
    ln -sf "$hdrdir" /usr/src/linux-rockchip-headers-"$(echo "$ver" | sed "s/-[^-]*$//")" 2>/dev/null || true
    [ -f "$hdrdir/Makefile" ] && (cd "$hdrdir" && make modules_prepare >/dev/null 2>&1) || true
  else
    echo "WARNING: headers dir for $ver not found under /usr/src" >&2
  fi
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
teardown_mountpoint $chroot_dir

cd ${chroot_dir} && tar --warning=no-file-changed -cpf "../ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar" . && cd .. && rm -rf ${chroot_dir}
../scripts/build-image.sh "ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"
rm -f "ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"
