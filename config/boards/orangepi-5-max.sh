# shellcheck shell=bash

export BOARD_NAME="Orange Pi 5 Max"
export BOARD_MAKER="Xulong"
export BOARD_SOC="Rockchip RK3588"
export BOARD_CPU="ARM Cortex A76 / A55"
export UBOOT_PACKAGE="u-boot-radxa-rk3588"
export UBOOT_RULES_TARGET="orangepi-5-max-rk3588"
#export COMPATIBLE_SUITES=("jammy" "noble" "oracular" "plucky")
export COMPATIBLE_SUITES=("noble")
export COMPATIBLE_FLAVORS=("server" "desktop")

function config_image_hook__orangepi-5-max() {
    local rootfs="$1"
    local overlay="$2"
    local suite="$3"

    chroot "${rootfs}" dpkg --add-architecture arm64

    # 基础源修正
    sed -i "s|http://archive.ubuntu.com/ubuntu|http://ports.ubuntu.com/ubuntu-ports/|g" "${rootfs}/etc/apt/sources.list"
    sed -i 's/^deb http/deb [arch=arm64] http/g' "${rootfs}/etc/apt/sources.list"

    chroot "${rootfs}" apt-get update

    if [ "${suite}" == "noble" ]; then
        chroot "${rootfs}" apt-get install -y --no-install-recommends \
            software-properties-common ca-certificates gnupg dirmngr dctrl-tools

        # 添加 PPA
        chroot "${rootfs}" add-apt-repository -y ppa:jjriek/rockchip
        chroot "${rootfs}" add-apt-repository -y ppa:jjriek/rockchip-multimedia
        
        echo "🔍 --- [修改前] 原始 PPA 配置文件内容 ---"
        find "${rootfs}/etc/apt/sources.list.d/" -type f -exec echo "File: {}" \; -exec cat {} \;
        
        # 针对 Noble 的多行格式插入架构锁定
        # 使用更稳健的匹配：在 URIs 这一行前面插入
        find "${rootfs}/etc/apt/sources.list.d/" -name "*.sources" -exec sed -i '/^URIs:/i Architectures: arm64' {} +
        find "${rootfs}/etc/apt/sources.list.d/" -name "*.list" -exec sed -i 's/^deb http/deb [arch=arm64] http/g' {} +

        echo "🔍 --- [修改后] PPA 配置文件内容 ---"
        find "${rootfs}/etc/apt/sources.list.d/" -type f -exec echo "File: {}" \; -exec cat {} \;

        # 暴力刷新缓存
        rm -rf "${rootfs}/var/lib/apt/lists/"*
        chroot "${rootfs}" apt-get update -o APT::Architectures="arm64"

        echo "🚨 --- 深度验货：检查包版本 ---"
        chroot "${rootfs}" apt-cache policy mpp
        chroot "${rootfs}" apt-cache showpkg $(chroot "${rootfs}" apt-cache dumpavail | grep -B1 'rockchip-multimedia' | grep 'Package:' | awk '{print $2}') | grep '^Package:'

        chroot "${rootfs}" apt-get -y -o APT::Architectures="arm64" install \
            mpp:arm64 \
            gstreamer1.0-rockchip:arm64
    fi
    
    if [ "TRUE" ]; then
        DOWNLOAD_URL="https://github.com/sfqr0414/test_action/releases/download/repo"
        DOWNLOAD_FILES=(#"armbian-firmware-gpu-panthor.deb" \
                        "armbian-firmware-wifi-ap6275p.deb" \
                        "bcmdhd-sdio-dkms_101.10.591.52.27-6_all.deb")

        # Ensure /tmp exists inside the rootfs so chroot can access downloaded packages.
        mkdir -p "${rootfs}/tmp"

        for file in "${DOWNLOAD_FILES[@]}"; do
            dst="${rootfs}/tmp/${file}"

            echo "开始下载到: ${dst}"
            # Download directly into rootfs/tmp
            wget -q -L -T 300 -O "${dst}" "${DOWNLOAD_URL}/${file}" || {
                echo "下载失败：${file}" >&2
                return 1
            }

            # Verify file exists on host
            if [[ ! -s "${dst}" ]]; then
                echo "下载失败：${file} 文件为空或不存在（宿主路径：${dst}）" >&2
                return 1
            fi
           
            chroot "${rootfs}" apt install -y "/tmp/${file}"
        done
    fi
    return 0
}
