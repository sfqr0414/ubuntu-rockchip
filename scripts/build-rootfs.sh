#!/bin/bash
set -eE

# Capture EXIT signal: print if exit code != 0
# $? is a Bash builtin; no extra var needed
trap '
    exit_code=$?  # save exit code (local to trap)
    if [ $exit_code -ne 0 ]; then
        echo "❌ Host script exited abnormally"
    fi
    exit $exit_code  # exit with original code
 ' EXIT

# Capture INT/TERM/QUIT and force exit
# trap 'echo "❌ Host script was forcibly terminated"; exit 1' INT TERM QUIT

# Basic configuration (YAML filename from FLAVOR)
HOST_ROOTFS_ROOT=$(cd $(dirname $0)/.. && pwd -P)
DOCKER_IMAGE="ubuntu-image-builder:plucky"
BUILD_DIR="${HOST_ROOTFS_ROOT}/build"  # Disk build/output directory

# Definitions directories
DEFINITIONS_DIR_HOST="${HOST_ROOTFS_ROOT}/definitions"       # Host definitions directory
DEFINITIONS_DIR_CONTAINER="/rootfs-build/definitions"        # Container definitions directory

# Require RELEASE_VERSION and FLAVOR
REQUIRED_ENVS=("RELEASE_VERSION" "FLAVOR")
for env in "${REQUIRED_ENVS[@]}"; do
    if [ -z "${!env}" ]; then
        echo "ERROR: ${env} environment variable not defined! Please export it from the parent script" >&2
        echo "Example: export RELEASE_VERSION=25.04; export FLAVOR=server" >&2
        exit 1
    fi
done

# Construct target file path
TARGET_FILE="build/ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz"

# Check whether the file exists in the build directory
if [[ -f "$TARGET_FILE" ]]; then  # quote filenames to handle spaces
    echo "found rootfs.tar.xz in build directory: $TARGET_FILE"
    exit 0
fi

# Auto-construct key paths
FINAL_TAR_PATH="${BUILD_DIR}/ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz"
TWEAKS_FILE="${DEFINITIONS_DIR_HOST}/tweaks.sh"                     # Host tweaks path
YAML_CONFIG_FILENAME="ubuntu-rootfs-${FLAVOR}.yaml"                  # YAML filename
YAML_CONFIG_FILE_HOST="${DEFINITIONS_DIR_HOST}/${YAML_CONFIG_FILENAME}"  # Host YAML full path
YAML_CONFIG_FILE_CONTAINER="${DEFINITIONS_DIR_CONTAINER}/${YAML_CONFIG_FILENAME}"  # Container YAML full path

# Pre-checks (ensure files exist)
# Check tweaks.sh
if [ ! -f "${TWEAKS_FILE}" ]; then
    echo "ERROR: tweaks.sh not found → ${TWEAKS_FILE}" >&2
    exit 1
fi

# Check YAML file
if [ ! -f "${YAML_CONFIG_FILE_HOST}" ]; then
    echo "ERROR: YAML configuration file not found → ${YAML_CONFIG_FILE_HOST}" >&2
    echo "Please ensure the YAML file for FLAVOR=${FLAVOR} (${YAML_CONFIG_FILENAME}) exists in the definitions directory" >&2
    exit 1
fi

# Clean old artifacts
rm -rf "${BUILD_DIR}/"*.tar.xz
rm -rf "${BUILD_DIR}/chroot" "${BUILD_DIR}/img"
mkdir -p "${BUILD_DIR}" "${BUILD_DIR}/img"

# Step 1: Docker Build
echo -e "\nStep 1: Docker Build - building image"
DOCKERFILE_DIR=$(mktemp -d)

docker_build_prepare(){
    (
    run_script() {
        set -e
        # Optional: change apt source mirrors:
        # sed -i.bak 's@http://archive.ubuntu.com/ubuntu/@http://mirrors.aliyun.com/ubuntu/@g' /etc/apt/sources.list
        apt-get update -y -qq
        apt-get install -y --no-install-recommends \
            debootstrap schroot qemu-user-static binfmt-support util-linux mount \
            procps apt-transport-https ca-certificates git build-essential devscripts \
            debhelper rsync xz-utils curl inotify-tools \
            ubuntu-keyring gnupg
        
        tmp_dir=$(mktemp -d)
        cd "${tmp_dir}" || exit 1
        git clone --depth 1 https://github.com/canonical/ubuntu-image.git
        cd ubuntu-image || exit 1
        touch ubuntu-image.rst
        apt-get build-dep . -y
        dpkg-buildpackage -us -uc -j$(nproc)
        apt-get install ../*.deb --assume-yes --allow-downgrades
        dpkg -i ../*.deb
        apt-mark hold ubuntu-image

        cd /
        rm -rf "${tmp_dir}"
        command -v ubuntu-image || exit 1
    }

    docker_build_file() {
        ARG UBUNTU_VERSION=25.04
        FROM ghcr.io/sfqr0414/ubuntu:${UBUNTU_VERSION}
        ENV DEBIAN_FRONTEND=noninteractive
        RUN << EOF 
        ${SUBSTITUTED_SCRIPT} 
EOF
        WORKDIR /rootfs-build
    }

    TEMPLATE_SCRIPT=$(type docker_build_file | extract_body)
    SUBSTITUTED_SCRIPT=$(type run_script | extract_body) 
    FINAL_SCRIPT="${TEMPLATE_SCRIPT//\$\{SUBSTITUTED_SCRIPT\}/$SUBSTITUTED_SCRIPT}"
    printf '%s' "$FINAL_SCRIPT" > "${DOCKERFILE_DIR}/Dockerfile" 
    )
    # Build image
    docker build \
        --no-cache \
        --pull \
        --progress=plain \
        -t "${DOCKER_IMAGE}" \
        "${DOCKERFILE_DIR}"
    rm -rf "${DOCKERFILE_DIR}"
}

docker_build_prepare

# Step 2: Docker Run
echo -e "\nStep 2: Docker Run - building Rootfs (disk-only)"

CONTAINER_SCRIPT=$(mktemp -p /tmp -t build-rootfs.XXXXXX.sh)
docker_run_prepare(){
    (
    run_script() {
        #!/bin/bash
        set -eE

        # Container paths
        BUILD_DIR="/rootfs-build/build"
        DEFINITIONS_DIR_CONTAINER="/rootfs-build/definitions"

        # Check envs passed to container
        REQUIRED_ENVS=("RELEASE_VERSION" "FLAVOR")
        for env in "${REQUIRED_ENVS[@]}"; do
            if [ -z "${!env}" ]; then
                echo "ERROR: ${env} environment variable not passed into container!" >&2
                exit 1
            fi
        done

        # Auto-construct paths
        FINAL_TAR_PATH="${BUILD_DIR}/ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz"
        TWEAKS_FILE="${DEFINITIONS_DIR_CONTAINER}/tweaks.sh"
        YAML_CONFIG_FILENAME="ubuntu-rootfs-${FLAVOR}.yaml"                  # YAML filename
        YAML_CONFIG_FILE="${DEFINITIONS_DIR_CONTAINER}/${YAML_CONFIG_FILENAME}"  # Container YAML full path

        # Cleanup
        cleanup() {
            echo -e "\n🔍 Triggering cleanup..."
            pkill inotifywait || true
            echo "✅ Cleanup done (artifacts preserved in ${BUILD_DIR})"
        }
        trap 'cleanup' EXIT INT TERM QUIT

        # Fix tweaks.sh permissions
        if [ -f "$TWEAKS_FILE" ]; then
            chmod +x "$TWEAKS_FILE"
            chown root:root "$TWEAKS_FILE"
            echo "✅ Fixed tweaks.sh permissions → ${TWEAKS_FILE}"
        else
            echo "ERROR: tweaks.sh not found inside container → ${TWEAKS_FILE}" >&2
            exit 1
        fi

        # Check YAML file
        if [ ! -f "${YAML_CONFIG_FILE}" ]; then
            echo "ERROR: YAML configuration file not found inside container → ${YAML_CONFIG_FILE}" >&2
            echo "Please ensure host definitions directory contains ${YAML_CONFIG_FILENAME}" >&2
            exit 1
        fi
        echo "var SUITE:${SUITE}"
        echo "before"
        cat "${YAML_CONFIG_FILE}"
        sed -i "s/placeholder/${SUITE}/g" "${YAML_CONFIG_FILE}"
        echo "after"
        cat "${YAML_CONFIG_FILE}"

        # Configure binfmt
        mkdir -p /proc/sys/fs/binfmt_misc
        mount -t binfmt_misc none /proc/sys/fs/binfmt_misc || true
        update-binfmts --package qemu-user-static --install qemu-aarch64 /usr/bin/qemu-aarch64-static \
            --magic '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00' \
            --mask '\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff' \
            --credentials yes --fix-binary yes
        update-binfmts --enable qemu-aarch64 || true
        /usr/bin/qemu-aarch64-static --version || { echo "qemu-aarch64-static not found"; exit 1; }

        # Ensure ubuntu archive keyring is available for debootstrap
        apt-get update -y -qq || true
        apt-get install -y --reinstall ubuntu-keyring debian-archive-keyring gnupg || true
        # Ensure keyring directory exists and has correct permissions
        mkdir -p /usr/share/keyrings
        
        # Configure debootstrap to use correct keyring and skip verification as fallback
        export DEBOOTSTRAP_OPTS="--keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg" #"--no-check-gpg"

        # Create a wrapper to inject DEBOOTSTRAP_OPTS into calls to debootstrap.
        # This avoids modifying ubuntu-image source. The wrapper lives in /usr/local/bin
        # which is typically earlier in PATH so it will be used in preference to the
        # system debootstrap.
        if [ ! -d /usr/local/bin ]; then
            mkdir -p /usr/local/bin
        fi

        cat > /usr/local/bin/debootstrap <<'EOF'
#!/bin/bash
# debootstrap wrapper: inject options from DEBOOTSTRAP_OPTS before passing args
REAL="/usr/sbin/debootstrap"
# fallback to whatever is available in PATH if /usr/sbin/debootstrap missing
if [ ! -x "$REAL" ]; then
    REAL="$(command -v debootstrap || true)"
fi
EXTRA="${DEBOOTSTRAP_OPTS:-}"
if [ -n "$EXTRA" ]; then
    exec $REAL $EXTRA "$@"
else
    exec $REAL "$@"
fi
EOF
        chmod +x /usr/local/bin/debootstrap
        # Ensure /usr/local/bin is earlier in PATH so the wrapper is used
        export PATH="/usr/local/bin:${PATH}"
        echo "✅ Installed debootstrap wrapper at /usr/local/bin/debootstrap (DEBOOTSTRAP_OPTS will be honored)"

        APT_BACKUP_PHYSICAL=".apt_shadow_backup"

        launch_messenger() {
            local base="$1"
            local FIFO="$base/.cmd_fifo"
            local ACK="$base/.cmd_ack"
            rm -f "$FIFO" "$ACK"
            mkfifo "$FIFO" && chmod 666 "$FIFO"
            exec 3<> "$FIFO"

            while true; do
                if read -r cmd <&3; then
                    [[ -z "$cmd" ]] && continue
                    if [[ "$cmd" == "TERMINATE" ]]; then break; fi
                    # 关键：宿主代劳，直接解决权限和节点问题
                    #chroot "$base" /bin/bash -c "$cmd" && touch "$ACK"
                    ( chroot "$base" /bin/bash -c "$cmd" )
                    local res=$?
                    echo "$res" > "$ACK"
                fi
            done
            rm -f "$FIFO" "$ACK"
        }

        # Monitor chroot creation via inotify
        (
            inotifywait -m -r -e CREATE,ISDIR --format '%w%f' "${BUILD_DIR}" | while read dir; do
                if [[ "$dir" == "${BUILD_DIR}/chroot" ]]; then
                    echo "✅ Detected chroot creation, waiting for subdirectories to initialize..."
                    until [ -d "${BUILD_DIR}/chroot/usr/bin" ]; do sleep 0.1; done
                    cp /usr/bin/qemu-aarch64-static "${BUILD_DIR}/chroot/usr/bin/"
                    chmod +x "${BUILD_DIR}/chroot/usr/bin/qemu-aarch64-static"
                    echo "✅ qemu copied to chroot"

                    mkdir -p "${BUILD_DIR}/chroot/${APT_BACKUP_PHYSICAL}"
                    echo "✅ Created physical backup directory inside chroot"

                    # 2. 启动并脱离父进程的信使
                    ( launch_messenger "${BUILD_DIR}/chroot" ) & disown

                    pkill inotifywait
                    exit 0
                fi
            done
        ) &
        MONITOR_PID=$!

        # Run ubuntu-image (auto-constructed YAML path)
        echo "🚀 Running ubuntu-image build (YAML: ${YAML_CONFIG_FILE})..."
        if ! ubuntu-image --debug \
            --workdir "${BUILD_DIR}" \
            --output-dir "${BUILD_DIR}/img" \
            classic "${YAML_CONFIG_FILE}"; then
          echo -e "\n❌ ubuntu-image execution failed"
          [ -f "${BUILD_DIR}/chroot/debootstrap/debootstrap.log" ] && cat $_ || echo "debootstrap log not found"
          [ -f "${BUILD_DIR}/img/build.log" ] && cat $_ || echo "ubuntu-image log not found"
          exit 1
        fi

        # Package artifact
        if ps -p $MONITOR_PID > /dev/null; then
            wait $MONITOR_PID || true
        fi

:<< "NOTES"
        EXCLUDE_DIRS=(
            # "var/lib/apt/lists/*"
            # "var/cache/apt/*"
            "var/cache/debconf/*"
            "tmp/*"
            "var/tmp/*"
            "var/log/*"
            "swapfile"
            "lost+found"
        )

        readarray -t EXCLUDE_PATHS < <(printf "%s\n" "${EXCLUDE_DIRS[@]}" | sed '1!s/^/--exclude=/')
        
        tar -cf - \
            -p -C "${BUILD_DIR}/chroot" \
            --sort=name \
            --xattrs \
            --sparse \
            --exclude=$EXCLUDE_PATHS \
            . \
            | xz -9 -e -T0 --memlimit=80% --block-size=128MiB > "${FINAL_TAR_PATH}"
NOTES
    }

    SUBSTITUTED_SCRIPT=$(type run_script | extract_body) 
    FINAL_SCRIPT="${SUBSTITUTED_SCRIPT}"
    printf '%s' "$FINAL_SCRIPT" > "${CONTAINER_SCRIPT}"
    )

    # Run container: only pass RELEASE_VERSION and FLAVOR
    docker run --rm -i \
        --privileged \
        --cap-add=ALL \
        -e RELEASE_VERSION="${RELEASE_VERSION}" \
        -e FLAVOR="${FLAVOR}" \
        -e SUITE="${SUITE}" \
        -v "${HOST_ROOTFS_ROOT}:/rootfs-build" \
        -v "${CONTAINER_SCRIPT}:/tmp/run-script.sh:ro" \
        "${DOCKER_IMAGE}" \
        /bin/bash /tmp/run-script.sh

    # Clean up container script
    rm -f "${CONTAINER_SCRIPT}"
}

docker_run_prepare

{
    set -x
    CHROOT_DIR=$(find "${BUILD_DIR}" -maxdepth 2 -type d -name "chroot" -print -quit)
    echo -e "CHROOT_DIR is $CHROOT_DIR"

    # 路径存在性校验：不存在就报错退出，防止空跑
    if [ -z "${CHROOT_DIR}" ]; then
        echo "❌ ERROR: 在 ${BUILD_DIR} 下物理搜索失败，未找到 chroot 目录！" >&2
        exit 1
    fi

    # 绝对化路径，确保变量稳固
    CHROOT_DIR=$(readlink -f "${CHROOT_DIR}")
    APT_BACKUP_PHYSICAL=".apt_shadow_backup"

    checkapt() {
        local path="$1"
        echo -e "\n check $path \n"
        ls -lh "$path/sources.list" || true
        cat "$path/sources.list" || true

        echo -e "\n check $path/sources.list.d/ \n"
        ls -lh "$path/sources.list.d" || true
        cat "$path/sources.list.d/"* || true
    }

    {
        echo -e "\n 🧐 Checking for PPA wipeout... \n"
        checkapt "$CHROOT_DIR/etc/apt"

        # 还原
        echo -e "\n⏪ Restoring from $CHROOT_DIR/${APT_BACKUP_PHYSICAL}\n"
        rm -rf "$CHROOT_DIR/etc/apt/"* || true
        cp -a "$CHROOT_DIR/${APT_BACKUP_PHYSICAL}/." "$CHROOT_DIR/etc/apt/" || true
        ls -lh "$CHROOT_DIR/etc/apt/" || true

        # 最终确认
        echo -e "\n 🧐 Checking for substituted  PPA ... \n"
        checkapt "$CHROOT_DIR/etc/apt"
    }

:<< "NOTES"
    {
        mount -l
        # 1. 查出身：看看它是哪种文件系统挂载的
        mount | grep "${BUILD_DIR}" || echo "BUILD_DIR is not a direct mount point (maybe part of rootfs)."

        # 2. 查深度：看看 chroot 目录下是否有隐藏的挂载（最危险的情况）
        echo "Checking for hidden mounts inside chroot..."
        mount | grep "$CHROOT_DIR" || echo "No sub-mounts detected in chroot."

        # 3. 查文件系统类型
        df -T "${BUILD_DIR}"

        # 4. 查 OverlayFS (这是内鬼常去的地方)
        if mount | grep -q "overlay"; then
            echo "⚠️ ALERT: OverlayFS detected! This might explain the 'sync' delay or missing files in tar."
        fi

        echo "--- Is chroot itself a mount? ---"
        mountpoint "$CHROOT_DIR" || echo "chroot is a regular directory (not a mountpoint)."

        # 3. 检查文件系统指纹
        echo "--- File System Type for chroot: ---"
        df -hT "$CHROOT_DIR"

        # 4. 查 inode 和设备号 (对比 /etc/apt 与备份目录)
        echo "--- Inode and Device Audit: ---"
        stat "$CHROOT_DIR/etc/apt"
        stat "$CHROOT_DIR/${APT_BACKUP_PHYSICAL}"
    }
NOTES

    echo "📦 Packaging rootfs (Release: ${RELEASE_VERSION}, Flavor: ${FLAVOR})..."

    FINAL_TAR_PATH="${BUILD_DIR}/ubuntu-${RELEASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz"

    sync

:<< "NOTES"
    {
     echo "🎣 正在投放多级熵值诱饵..."

     # 诱饵 A：放在根目录（检测整个 chroot 是否被还原）
     sudo dd if=/dev/urandom of="${CHROOT_DIR}/GLOBAL_TRAP.raw" bs=1M count=2048 status=none

     # 诱饵 B：放在 etc 目录（检测系统配置层是否被还原）
     sudo dd if=/dev/urandom of="${CHROOT_DIR}/etc/CONFIG_TRAP.raw" bs=1M count=1024 status=none

     # 诱饵 C：放在 apt 目录（检测是否只有 apt 目录被针对性清理）
     sudo dd if=/dev/urandom of="${CHROOT_DIR}/etc/apt/APT_SPECIFIC_TRAP.raw" bs=1M count=512 status=none

     echo "🧐 投放后物理确认:"
     sudo ls -lh "${CHROOT_DIR}/GLOBAL_TRAP.raw"
     sudo ls -lh "${CHROOT_DIR}/etc/CONFIG_TRAP.raw"
     sudo ls -lh "${CHROOT_DIR}/etc/apt/APT_SPECIFIC_TRAP.raw"
     sudo sync
    }
NOTES
    
    tar -cJf "${FINAL_TAR_PATH}" \
        -p -C "$CHROOT_DIR" . \
        --sort=name \
        --xattrs

    TMP_CHROOT="./image"
    ls -l "${FINAL_TAR_PATH}"
    mkdir -p "$TMP_CHROOT"
    tar -xpI 'xz -d -T0' -f "${FINAL_TAR_PATH}" -C "${TMP_CHROOT}"

    {
        echo "list directory for ${FINAL_TAR_PATH}"
        ls -lh "${FINAL_TAR_PATH}"

        echo -e "\n------ 🧐 Checking for PPA exist ------ \n"
        checkapt "${TMP_CHROOT}/etc/apt"

        echo -e "\n------ 🧐 Checking for PPA backup ${APT_BACKUP_PHYSICAL} ------ \n"
        checkapt "${TMP_CHROOT}/${APT_BACKUP_PHYSICAL}"
    }
    set +x
}

# Verify artifact
echo -e "\n🔍 Verify artifact:"
ls -lh ${FINAL_TAR_PATH} && echo "🎉 Build successful! Artifact path: ${FINAL_TAR_PATH}"
        
# Host verification
if [ -f "${FINAL_TAR_PATH}" ]; then
    echo -e "\n----------------------------------------"
    echo "🎉 Overall build succeeded!"
    echo "📁 Artifact path: ${FINAL_TAR_PATH}"
    echo "📏 Artifact size: $(du -sh "${FINAL_TAR_PATH}" | awk '{print $1}')"
    echo "✅ Release: ${RELEASE_VERSION} | Flavor: ${FLAVOR} | YAML: ${YAML_CONFIG_FILENAME}"
    echo "----------------------------------------"
else
    echo -e "\n❌ Build failed: artifact not produced" >&2
    ls -la "${BUILD_DIR}/"
    exit 1
fi

# Clear trap handlers
trap - EXIT INT TERM QUIT
