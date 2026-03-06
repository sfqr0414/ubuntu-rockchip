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
        sed -i 's/^series: plucky$/series: '"$SUITE"'/' "${YAML_CONFIG_FILE}"
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

        {
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
        } > /usr/local/bin/debootstrap

        cat /usr/local/bin/debootstrap
        
        chmod +x /usr/local/bin/debootstrap
        # Ensure /usr/local/bin is earlier in PATH so the wrapper is used
        export PATH="/usr/local/bin:${PATH}"
        echo "✅ Installed debootstrap wrapper at /usr/local/bin/debootstrap (DEBOOTSTRAP_OPTS will be honored)"

        # Monitor chroot creation via inotify
        (
            inotifywait -m -r -e CREATE,ISDIR --format '%w%f' "${BUILD_DIR}" | while read dir; do
                if [[ "$dir" == "${BUILD_DIR}/chroot" ]]; then
                    echo "✅ Detected chroot creation, waiting for subdirectories to initialize..."
                    until [ -d "${BUILD_DIR}/chroot/usr/bin" ]; do sleep 0.1; done
                    cp /usr/bin/qemu-aarch64-static "${BUILD_DIR}/chroot/usr/bin/"
                    chmod +x "${BUILD_DIR}/chroot/usr/bin/qemu-aarch64-static"
                    echo "✅ qemu copied to chroot"
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
        
        echo "📦 Packaging rootfs (Release: ${RELEASE_VERSION}, Flavor: ${FLAVOR})..."

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

        EXCLUDE_PATHS="{$(printf "%s," "${EXCLUDE_DIRS[@]}" | sed 's/,$//')}"
        
        tar -cf - \
            -p -C "${BUILD_DIR}/chroot" \
            --sort=name \
            --xattrs \
            --exclude=$EXCLUDE_PATHS \
            . \
            | xz -9 -e -T0 --memlimit=80% --block-size=128MiB > "${FINAL_TAR_PATH}"

        # Verify artifact
        echo -e "\n🔍 Verify artifact:"
        ls -lh ${FINAL_TAR_PATH}
        echo "🎉 Build successful! Artifact path: ${FINAL_TAR_PATH}"
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
        -v "${BUILD_DIR}:/rootfs-build/build" \
        -v "${CONTAINER_SCRIPT}:/tmp/run-script.sh:ro" \
        "${DOCKER_IMAGE}" \
        /bin/bash /tmp/run-script.sh

    # Clean up container script
    rm -f "${CONTAINER_SCRIPT}"
}

docker_run_prepare

# Host verification
set +x
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
