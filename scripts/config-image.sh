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

    # 找到所有 kernel 相关 deb 包
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
chroot $chroot_dir apt-get -y upgrade

if [[ ${LAUNCHPAD} == "Y" ]]; then
    chroot ${chroot_dir} apt-get -y install "u-boot-${BOARD}"
else
    mkdir -p ${chroot_dir}/tmp

    # 安装 u-boot
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

    # 复制全部 kernel deb，改短名
    for deb in "${kernel_debs[@]}"; do
        if [ ! -f "./$deb" ]; then
            echo "Error: missing deb file $deb"
            ls -lh
            exit 1
        fi
        base_name=$(echo "$deb" | sed 's/_.*//')
        cp "./$deb" "${chroot_dir}/tmp/${base_name}.deb"
    done

    # 校验拷贝
    ls -lh "${chroot_dir}/tmp/"

    # ========== 改进：先安装 headers，再安装其余 kernel 包（image/modules/buildinfo） ==========
    # 1) 准备 deb 列表并识别 headers 包（优先安装）
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

    # 2) 先安装 headers（如果存在），并修复依赖
    if [ -n "${header_deb}" ]; then
        echo "Installing kernel headers first: ${header_deb}"
        chroot "${chroot_dir}" /bin/bash -lc "set -e; dpkg -i ${header_deb} 2>/tmp/dpkg_headers_install.log || true; apt-get update -y; apt-get -f install -y"
    fi

    # 3) 然后安装剩余 kernel packages（image/modules/buildinfo）
    echo "Installing kernel packages: ${deb_files}"
    chroot "${chroot_dir}" /bin/bash -lc "set -e; dpkg -i ${deb_files} 2>/tmp/dpkg_kern_install.log || apt-get -fy install -y"

    # 4) 更保守地准备 headers：安装必需工具（flex/bison 等），只运行 make modules_prepare（避免 make scripts）
    chroot "${chroot_dir}" /bin/bash -lc '
set -e

# 找到合适的 headers 目录（优先 6.1.x）
HDRDIR="$(ls -d /usr/src/linux-headers-6.1.* 2>/dev/null | head -n1 || true)"
if [ -z "$HDRDIR" ]; then
  HDRDIR="$(ls -d /usr/src/linux-headers-* 2>/dev/null | head -n1 || true)"
fi

if [ -z "$HDRDIR" ]; then
  echo "WARN: HDRDIR not found; ensure matching linux-headers package is installed" >&2
  exit 0
fi

# 从 hdrdir 派生 kernel 版本字符串并确保 /lib/modules/<ver>/build 指向它
ver="$(basename "$HDRDIR" | sed "s/^linux-headers-//")"
mkdir -p "/lib/modules/$ver"
ln -sf "$HDRDIR" "/lib/modules/$ver/build"
echo "INFO: linked /lib/modules/$ver/build -> $HDRDIR"

# 安装严格需要的构建工具（确保 flex/bison 在先）
apt-get update -y || true
apt-get install -y --no-install-recommends \
  build-essential make bc dkms libncurses-dev libelf-dev perl python3 \
  flex bison || true

# sanity: ensure flex and bison are available
if ! command -v flex >/dev/null 2>&1; then
  echo "ERROR: flex not found after install" >&2
  exit 1
fi
if ! command -v bison >/dev/null 2>&1; then
  echo "ERROR: bison not found after install" >&2
  exit 1
fi

# 仅运行 modules_prepare（避免运行 make scripts 导致 SELinux/genheaders 等 host 工具完整编译）
if [ -f "$HDRDIR/Makefile" ]; then
  echo "INFO: running make modules_prepare in $HDRDIR"
  (cd "$HDRDIR" && make modules_prepare) || {
    echo "ERROR: make modules_prepare failed in $HDRDIR" >&2
    tail -n 100 "$HDRDIR"/scripts/* 2>/dev/null || true
    exit 1
  }
else
  echo "WARN: $HDRDIR/Makefile not found"
fi

# 验证关键生成文件是否存在
if [ -f "$HDRDIR/include/generated/utsrelease.h" ] || [ -f "/lib/modules/$ver/build/Makefile" ]; then
  echo "INFO: headers appear prepared for $ver"
else
  echo "WARN: headers may be incomplete for $ver" >&2
  ls -la "$HDRDIR" || true
  ls -la "/lib/modules/$ver" || true
fi
'

    # 5) NOTE: 不在这里安装任何 DKMS 包 — 板级 hook（config_image_hook__<board>）负责安装 bcmdhd/dkms 驱动
    #    这样可保证 hook 在 headers 已准备好时运行，避免重复或顺序问题。

    # 6) 在 kernel 安装完成后再将 kernel 包 hold，防止后续 apt upgrade 覆盖它们
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
    # 在这里调用板级 hook：hook 中应负责安装 bcmdhd/dkms（因为 headers 已准备好）
    config_image_hook__"${BOARD}" "${chroot_dir}" "${overlay_dir}" "${SUITE}"
fi

chroot ${chroot_dir} update-initramfs -u
chroot ${chroot_dir} apt-get -y clean
chroot ${chroot_dir} apt-get -y autoclean
chroot ${chroot_dir} apt-get -y autoremove
teardown_mountpoint $chroot_dir

# 核心打包+清理命令（优化日志+排除无用目录）
cd ${chroot_dir} && tar --warning=no-file-changed -cpf "../ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar" . && cd .. && rm -rf ${chroot_dir}
../scripts/build-image.sh "ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"
rm -f "ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"
