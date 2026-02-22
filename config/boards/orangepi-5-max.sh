# shellcheck shell=bash

export BOARD_NAME="Orange Pi 5 Max"
export BOARD_MAKER="Xulong"
export BOARD_SOC="Rockchip RK3588"
export BOARD_CPU="ARM Cortex A76 / A55"
export UBOOT_PACKAGE="u-boot-radxa-rk3588"
export UBOOT_RULES_TARGET="orangepi-5-max-rk3588"
#export COMPATIBLE_SUITES=("jammy" "noble" "oracular" "plucky")
export COMPATIBLE_SUITES=("plucky")
#export COMPATIBLE_FLAVORS=("server" "desktop")
export COMPATIBLE_FLAVORS=("desktop")

function config_image_hook__orangepi-5-max() {
    local rootfs="$1"
    local overlay="$2"
    local suite="$3"

    if [ "${suite}" == "jammy" ] || [ "${suite}" == "noble" ]; then
        # Kernel modules to blacklist
        echo "blacklist bcmdhd" > "${rootfs}/etc/modprobe.d/bcmdhd.conf"
        echo "blacklist dhd_static_buf" >> "${rootfs}/etc/modprobe.d/bcmdhd.conf"

        # Install panfork
        chroot "${rootfs}" add-apt-repository -y ppa:jjriek/panfork-mesa
        chroot "${rootfs}" apt-get update
        chroot "${rootfs}" apt-get -y install mali-g610-firmware
        chroot "${rootfs}" apt-get -y dist-upgrade

        # Install libmali blobs alongside panfork
        chroot "${rootfs}" apt-get -y install libmali-g610-x11

        # Install the rockchip camera engine
        chroot "${rootfs}" apt-get -y install camera-engine-rkaiq-rk3588

        # Install BCMDHD SDIO WiFi and Bluetooth DKMS (do not print make.log here)
        chroot "${rootfs}" apt-get -y install dkms bcmdhd-sdio-dkms

        # Enable bluetooth
        cp "${overlay}/usr/bin/brcm_patchram_plus" "${rootfs}/usr/bin/brcm_patchram_plus"
        cp "${overlay}/usr/lib/systemd/system/ap6611s-bluetooth.service" "${rootfs}/usr/lib/systemd/system/ap6611s-bluetooth.service"
        chroot "${rootfs}" systemctl enable ap6611s-bluetooth

        # Install wiring orangepi package 
        chroot "${rootfs}" apt-get -y install wiringpi-opi libwiringpi2-opi libwiringpi-opi-dev
        echo "BOARD=orangepi5max" > "${rootfs}/etc/orangepi-release"
    else
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

            echo "宿主上文件信息："
            ls -l "${dst}" || true

            # Verify chroot can see the file
            echo "在 chroot 内检查 /tmp/${file} 是否存在："
            if ! chroot "${rootfs}" ls -l "/tmp/${file}" > /dev/null 2>&1; then
                echo "ERROR: chroot 内找不到 /tmp/${file}（宿主路径：${dst}）" >&2
                # 打印宿主上的前 200 字节用于排查（若误下载到 HTML）
                head -c 200 "${dst}" | sed -n '1,40p' >&2 || true
                return 1
            fi
            chroot "${rootfs}" ls -l "/tmp/${file}" || true

            echo "下载成功：${file}"
            # 使用 chroot 内的 apt 安装（路径为 /tmp/<file>）
            if [[ "${file}" == "bcmdhd-sdio-dkms"* ]]; then
                # 捕获安装退出码，避免set -e直接退出导致日志无法打印
                local install_exit_code=0
                chroot "${rootfs}" apt install -y "/tmp/${file}" || install_exit_code=$?
                
                # 安装后强制打印完整DKMS日志（修复路径匹配问题+执行时机问题）
                echo "===== DKMS make.log 完整内容 ====="
                chroot "${rootfs}" /bin/bash -lc '
shopt -s nullglob
for log in /var/lib/dkms/bcmdhd-sdio/*/build/make.log; do
  [ -f "$log" ] || continue
  echo "===== 日志路径: $log ====="
  cat "$log"
done
' || true

                # 安装失败则返回错误
                if [[ ${install_exit_code} -ne 0 ]]; then
                    echo "ERROR: ${file} 安装失败，退出码: ${install_exit_code}" >&2
                    return ${install_exit_code}
                fi
            else
                chroot "${rootfs}" apt install -y "/tmp/${file}"
            fi
        done
    fi
    return 0
}
