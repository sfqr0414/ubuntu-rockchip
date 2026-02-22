# shellcheck shell=bash

export BOARD_NAME="Orange Pi 5 Max"
export BOARD_MAKER="Xulong"
export BOARD_SOC="Rockchip RK3588"
export BOARD_CPU="ARM Cortex A76 / A55"
export UBOOT_PACKAGE="u-boot-radxa-rk3588"
export UBOOT_RULES_TARGET="orangepi-5-max-rk3588"
#export COMPATIBLE_SUITES=("jammy" "noble" "oracular" "plucky")
export COMPATIBLE_SUITES=("plucky")
export COMPATIBLE_FLAVORS=("server" "desktop")

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

        # Install BCMDHD SDIO WiFi and Bluetooth DKMS (no make.log printing here)
        chroot "${rootfs}" apt-get -y install dkms bcmdhd-sdio-dkms

        # Enable bluetooth
        cp "${overlay}/usr/bin/brcm_patchram_plus" "${rootfs}/usr/bin/brcm_patchram_plus"
        cp "${overlay}/usr/lib/systemd/system/ap6611s-bluetooth.service" "${rootfs}/usr/lib/systemd/system/ap6611s-bluetooth.service"
        chroot "${rootfs}" systemctl enable ap6611s-bluetooth

        # Install wiring orangepi package 
        chroot "${rootfs}" apt-get -y install wiringpi-opi libwiringpi2-opi libwiringpi-opi-dev
        echo "BOARD=orangepi5max" > "${rootfs}/etc/orangepi-release"
    else
    (
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
            exit 1
        }

        # Verify file exists on host
        if [[ ! -s "${dst}" ]]; then
            echo "下载失败：${file} 文件为空或不存在（宿主路径：${dst}）" >&2
            exit 1
        fi

        echo "宿主上文件信息："
        ls -l "${dst}" || true

        # Verify chroot can see the file
        echo "在 chroot 内检查 /tmp/${file} 是否存在："
        if ! chroot "${rootfs}" ls -l "/tmp/${file}" > /dev/null 2>&1; then
            echo "ERROR: chroot 内找不到 /tmp/${file}（宿主路径：${dst}）" >&2
            # 打印宿主上的前 200 字节用于排查（若误下载到 HTML）
            head -c 200 "${dst}" | sed -n '1,40p' >&2 || true
            exit 1
        fi
        chroot "${rootfs}" ls -l "/tmp/${file}" || true

        echo "下载成功：${file}"

        # Minimal: if this is the bcmdhd dkms deb, ensure fixdep exists by preparing headers inside chroot (very small, non-messy block)
        if [[ "${file}" == *"bcmdhd-sdio-dkms"* ]]; then
            echo ">>> Preparing kernel headers inside chroot (minimal: install deps & run make scripts/modules_prepare if needed)"
            chroot "${rootfs}" /bin/bash -lc '
set -e
# determine kernel version and hdrdir
KVER="$(ls /lib/modules 2>/dev/null | grep -i rockchip | sort -V | tail -n1 || true)"
if [ -z "$KVER" ]; then
  KVER="$(ls /lib/modules 2>/dev/null | sort -V | tail -n1 || true)"
fi
SHORT="$(echo "$KVER" | sed "s/-[^-]*$//")"
HDRDIR="$(ls -d /usr/src/*${KVER}* 2>/dev/null | head -n1 || true)"
if [ -z "$HDRDIR" ]; then
  HDRDIR="$(ls -d /usr/src/*${SHORT}* 2>/dev/null | head -n1 || true)"
fi

echo "DEBUG: KVER=$KVER"
echo "DEBUG: HDRDIR=$HDRDIR"

if [ -n "$HDRDIR" ]; then
  # install minimal build deps required for generating scripts/basic/fixdep
  apt-get update -y || true
  apt-get install -y build-essential bison flex libncurses-dev libelf-dev bc python3 perl dkms || true

  # generate kernel scripts and prepare modules
  make -C "$HDRDIR" scripts || true
  make -C "$HDRDIR" modules_prepare || true

  if [ -f "$HDRDIR/scripts/basic/fixdep" ]; then
    echo "INFO: fixdep present at $HDRDIR/scripts/basic/fixdep"
  else
    echo "WARN: fixdep still missing under $HDRDIR/scripts/basic"
  fi
else
  echo "WARN: HDRDIR not found; ensure matching linux-headers are installed in chroot"
fi
' || true
        fi

        # Use chroot's apt to install the .deb (this will trigger DKMS postinst)
        chroot "${rootfs}" apt install -y "/tmp/${file}"
    done

    # After installing all downloaded .debs, do not aggregate logs here; config-image.sh will copy out DKMS logs if needed.
    )
    fi
    return 0
}
