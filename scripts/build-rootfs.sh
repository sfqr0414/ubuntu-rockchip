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
        REQUIRED_ENVS=("RELEASE_VERSION" "FLAVOR
