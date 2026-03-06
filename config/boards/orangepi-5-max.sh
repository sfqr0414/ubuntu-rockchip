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

    chroot "${rootfs}" dpkg --print-architecture 

    if [ "${suite}" == "noble" ]; then
        chroot "${rootfs}" apt-get update
        chroot "${rootfs}" apt-get install -y --no-install-recommends software-properties-common ca-certificates gnupg dirmngr

        chroot "${rootfs}" add-apt-repository -y "deb [arch=arm64] https://ppa.launchpadcontent.net/jjriek/rockchip/ubuntu noble main"
        chroot "${rootfs}" add-apt-repository -y "deb [arch=arm64] https://ppa.launchpadcontent.net/jjriek/rockchip-multimedia/ubuntu noble main"

        rm -rf "${rootfs}/var/lib/apt/lists/"*
        chroot "${rootfs}" apt-get update -o APT::Architectures="arm64"

        echo "🚨 --- 深度验货：检查包版本 ---"
        chroot "${rootfs}" sh -c "grep '^Package:' /var/lib/apt/lists/\$(ls /var/lib/apt/lists/ | grep rockchip-multimedia | grep _Packages | head -n1)"

        local packages=(
            "mpp:arm64"
            "gstreamer1.0-rockchip:arm64"
        )

        for pkg in "${packages[@]}"; do
            local pkg_name="${pkg%%:*}"
            
            echo "🔍 验证货架状态: ${pkg_name}"
            chroot "${rootfs}" apt-cache policy "${pkg_name}"

            echo "🚀 正在安装: ${pkg}"
            chroot "${rootfs}" apt-get install -y -o APT::Architectures="arm64" "${pkg}"
        done
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
