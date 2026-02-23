#!/bin/bash
set -eE 

SCRIPT_DIR=$(cd "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
ORIGINAL_PWD="$PWD"

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

    # Find all kernel-related deb packages
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

# Export chroot wrapper (avoids hardcoded path)
chroot() {
    runner() {
        command chroot "$@" & local child_pid=$!
        set +e
        wait $child_pid; local ret=$?
        echo "Command 'chroot $@' exited with status $ret"
        if [ $ret -ne 0 ]; then
            if [ $ret -eq 130 ] || [ $ret -eq 143 ]; then
                sudo kill -9 $child_pid 2>/dev/null
                exit $ret
            fi
        fi
        set -e
        return $ret
    }
    time runner "$@"
    return $?
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
    error "-- [cleanup] unmounting mountpoints --"
    set +e
    cd "$ORIGINAL_PWD" 2>/dev/null
    cd build 2>/dev/null
    local mountpoint
    mountpoint=$(realpath "$1" 2>/dev/null)
    if [ -n "$mountpoint" ] && [ -d "$mountpoint" ]; then
        awk -v mp="$mountpoint" '$2 ~ "^"mp { print $2 }' /proc/self/mounts | LC_ALL=C sort -r | xargs -r umount -l 2>/dev/null
        [ -f resolv.conf.tmp ] && mv -f resolv.conf.tmp "$mountpoint/etc/resolv.conf" 2>/dev/null
        [ -f nsswitch.conf.tmp ] && mv -f nsswitch.conf.tmp "$mountpoint/etc/nsswitch.conf" 2>/dev/null
    fi
    set -e
}

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

chroot_dir=rootfs
overlay_dir=../overlay

# Trap exit signals to teardown_mountpoint
trap 'teardown_mountpoint "$chroot_dir"' EXIT INT TERM HUP QUIT

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

    # Install u-boot
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

    # Copy all kernel debs and shorten their names
    for deb in "${kernel_debs[@]}"; do
        if [ ! -f "./$deb" ]; then
            echo "Error: missing deb file $deb"
            ls -lh
            exit 1
        fi
        base_name=$(echo "$deb" | sed 's/_.*//')
        cp "./$deb" "${chroot_dir}/tmp/${base_name}.deb"
    done

    # Verify copies
    ls -lh "${chroot_dir}/tmp/"

    # Install kernel debs
    deb_files=""
    for deb in "${kernel_debs[@]}"; do
        base_name=$(echo "$deb" | sed 's/_.*//')
        deb_files+="/tmp/${base_name}.deb "
    done
    chroot ${chroot_dir} /bin/bash -c "apt-get -y purge \$(dpkg --list | grep -Ei 'linux-image|linux-headers|linux-modules|linux-rockchip' | awk '{ print \$2 }')"
    chroot "${chroot_dir}" dpkg -i $deb_files || chroot "${chroot_dir}" apt-get -fy install

    # Hold kernel packages to prevent upgrades
    for deb in "${kernel_debs[@]}"; do
        base_name=$(echo "$deb" | sed 's/_.*//')
        chroot "${chroot_dir}" apt-mark hold "${base_name}"
    done

    # Determine installed kernel version for hooks
    kernel_versions=()
    for deb in "${kernel_debs[@]}"; do
        if [[ "$deb" == linux-image-* ]]; then
            version=${deb#linux-image-}
            version=${version%%_*}
            kernel_versions+=("${version}")
        fi
    done
    if [[ ${#kernel_versions[@]} -gt 0 ]]; then
        mapfile -t sorted_kernel_versions < <(printf '%s\n' "${kernel_versions[@]}" | sort -V)
        target_kernel_version="${sorted_kernel_versions[$(( ${#sorted_kernel_versions[@]} - 1 ))]}"
        export TARGET_KERNEL_VERSION="${target_kernel_version}"
    fi
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

# Keep original trap unbinding logic; no conflict
trap - EXIT INT TERM HUP QUIT
teardown_mountpoint $chroot_dir

# Finalize package and cleanup
cd ${chroot_dir} && tar --warning=no-file-changed -cpf "../ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar" . && cd .. && rm -rf ${chroot_dir}
../scripts/build-image.sh "ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"
rm -f "ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"