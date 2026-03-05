#!/bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

# Docker init & version parse
# Docker image name
DOCKER_IMAGE="ubuntu-kernel-u-boot-build:dynamic"

# Robust path resolution
SCRIPT_PATH=$(realpath "$0" 2>/dev/null || readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
HOST_KERNEL_ROOT=$(realpath "${SCRIPT_DIR}/.." 2>/dev/null)
# Path debug
echo "Path debug info:"
echo "Script absolute path: ${SCRIPT_PATH}"
echo "Script directory: ${SCRIPT_DIR}"
echo "Kernel build root: ${HOST_KERNEL_ROOT}"

# Ubuntu mirror
UBUNTU_MIRROR="hub-mirror.c.163.com/library/ubuntu"

# Check SUITE is set
if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set (e.g. export SUITE=plucky)"
    exit 1
fi

# Load suite config
SUITE_CONFIG_FILE="${HOST_KERNEL_ROOT}/config/suites/${SUITE}.sh"
if [ ! -f "${SUITE_CONFIG_FILE}" ]; then
    echo "Error: Suite config file not found → ${SUITE_CONFIG_FILE}"
    exit 1
fi
# shellcheck source=/dev/null
source "${SUITE_CONFIG_FILE}"

# Extract Ubuntu version
UBUNTU_VERSION="${RELEASE_VERSION}"
# Ensure UBUNTU_VERSION set
if [ -z "${UBUNTU_VERSION}" ]; then
    echo "Error: RELEASE_VERSION not defined in ${SUITE_CONFIG_FILE} or is empty"
    echo "Please ensure ${SUITE_CONFIG_FILE} defines RELEASE_VERSION, e.g. RELEASE_VERSION=\"25.04\""
    exit 1
fi
# Verify core vars
echo "Core variables:"
echo "SUITE: ${SUITE}"
echo "RELEASE_VERSION: ${RELEASE_VERSION}"
echo "UBUNTU_VERSION: ${UBUNTU_VERSION}"

# Fix Docker permissions
fix_docker_permission() {
    echo "Checking Docker permissions"
    # Support non-systemctl envs
    if command -v systemctl &>/dev/null; then
        if ! systemctl is-active --quiet docker; then
            echo "Starting Docker service..."
            systemctl start docker || echo "Warning: failed to start Docker service (may be Docker Desktop)"
            systemctl enable docker || true
        fi
    fi

    # Fix Docker socket perms
    DOCKER_SOCK="/var/run/docker.sock"
    if [ -S "${DOCKER_SOCK}" ] && [ ! -w "${DOCKER_SOCK}" ]; then
        echo "Fixing Docker socket permissions..."
        chmod 666 "${DOCKER_SOCK}" || echo "Warning: unable to change ${DOCKER_SOCK} permissions"
        if [ -n "${SUDO_USER}" ]; then
            usermod -aG docker "${SUDO_USER}" || true
            newgrp docker &> /dev/null
        fi
    fi

    # Verify Docker availability
    if ! docker info &> /dev/null; then
        echo "Error: Docker permission fix failed or Docker not installed; check Docker setup"
        exit 1
    fi
    echo "Docker permission check passed"
}

# Basic checks
# Check Docker installed
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    apt-get update && apt-get install -y --no-install-recommends docker.io
    if [ -n "${SUDO_USER}" ]; then
        usermod -aG docker "${SUDO_USER}" || true
        newgrp docker &> /dev/null
    fi
fi

# Fix Docker permission
fix_docker_permission

# Detect GCC version
echo "Parsing configuration:"
echo "Suite: ${SUITE}"
echo "Ubuntu version: ${UBUNTU_VERSION}"
echo "Kernel branch: ${KERNEL_BRANCH:-undefined}"
echo "Kernel repository: ${KERNEL_REPO:-undefined}"

# Detect GCC version
EXPECTED_GCC_VERSION=$(docker run --rm --entrypoint /bin/bash \
    -e DEBIAN_FRONTEND=noninteractive \
    -e DEBCONF_NONINTERACTIVE_SEEN=true \
    ghcr.io/sfqr0414/ubuntu:"${UBUNTU_VERSION}" -c "
    apt-get update -qq >/dev/null && 
    apt-get install -qq --no-install-recommends gcc -y >/dev/null && 
    gcc --version | head -1 | awk '{print \$4}' | sed 's/)//'
")

if [ -z "${EXPECTED_GCC_VERSION}" ]; then
    echo "Error: unable to get GCC version for Ubuntu ${UBUNTU_VERSION}"
    exit 1
fi

echo "Ubuntu ${UBUNTU_VERSION} default GCC version: ${EXPECTED_GCC_VERSION}"

TEMP_DOCKERFILE=$(mktemp)
echo "Debug: temporary Dockerfile path = ${TEMP_DOCKERFILE}"
docker_build_prepare(){
    (
    run_script() {
        #!/bin/bash
        set -eE
        #trap 'echo "environment build error: line $LINENO"; exit 1' ERR

        # Install dependencies
        apt-get update && \
        apt-get upgrade -y || true && \
        apt-get install -y --no-install-recommends \
            lsb-release \
            debhelper fakeroot build-essential dpkg-dev devscripts \
            bc bison flex libssl-dev libncurses-dev libelf-dev dwarves \
            gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
            git wget libterm-readline-gnu-perl \
            gawk cpio kmod && \
        echo "Check gawk path after install:" && \
        which gawk || (echo "gawk not found after install, reinstalling" && apt-get install -y --reinstall gawk) && \
        apt-get clean && rm -rf /var/lib/apt/lists/*

        # Verify Ubuntu version
        ACTUAL_UBUNTU_VERSION=$(lsb_release -rs)
        echo "Container Ubuntu version: $ACTUAL_UBUNTU_VERSION"
        echo "Expected Ubuntu version: $UBUNTU_VERSION"
        if [ "$ACTUAL_UBUNTU_VERSION" != "$UBUNTU_VERSION" ]; then
            echo "Version mismatch: expected $UBUNTU_VERSION, actual $ACTUAL_UBUNTU_VERSION"
            exit 1
        fi

        # Verify GCC version
        ACTUAL_GCC_VERSION=$(gcc --version | head -1 | awk '{print $4}' | sed 's/)//')
        echo "Container GCC version: $ACTUAL_GCC_VERSION"
        echo "Expected GCC version: $EXPECTED_GCC_VERSION"
        if [ "$ACTUAL_GCC_VERSION" != "$EXPECTED_GCC_VERSION" ]; then
            echo "GCC version mismatch: expected $EXPECTED_GCC_VERSION, actual $ACTUAL_GCC_VERSION"
            exit 1
        fi

        # Extra gawk checks
        echo "Debug: gawk installation"
        echo "Current PATH: $PATH"
        ls -l /usr/bin/gawk* || true

        # Check gawk executable
        if [ ! -x "/usr/bin/gawk" ]; then
            echo "Error: gawk executable not found or not executable"
            echo "File info:" && stat /usr/bin/gawk || true
            echo "Installed package info:" && dpkg -l gawk
            exit 1
        else
            echo "gawk installed successfully, version: $(gawk --version | head -1)"
            echo "gawk path: $(which gawk)"
            echo "gawk self-test: $(echo '1+1' | gawk '{print \$1}')"
        fi
    }

    docker_build_file() {
        # ARGs (before FROM)
        ARG UBUNTU_VERSION
        # Base image
        FROM ghcr.io/sfqr0414/ubuntu:${UBUNTU_VERSION}
        # Define container ARGs
        ARG UBUNTU_VERSION
        ARG EXPECTED_GCC_VERSION
        # Global env vars
        ENV DEBIAN_FRONTEND=noninteractive
        ENV DEBCONF_NONINTERACTIVE_SEEN=true
        ENV LANG=C.UTF-8
        ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        # HEREDOC script
        RUN << EOF 
        ${SUBSTITUTED_SCRIPT} 
EOF
        # Set working directory
        WORKDIR /kernel-build
    }

    TEMPLATE_SCRIPT=$(type docker_build_file | extract_body)
    SUBSTITUTED_SCRIPT=$(type run_script | extract_body) 
    FINAL_SCRIPT="${TEMPLATE_SCRIPT//\$\{SUBSTITUTED_SCRIPT\}/$SUBSTITUTED_SCRIPT}"
    printf '%s' "$FINAL_SCRIPT" > "${TEMP_DOCKERFILE}" 
    )

    # Run Docker build
    echo "Executing Docker build"
    echo "Passing args:"
    echo "  --build-arg UBUNTU_VERSION=${UBUNTU_VERSION}"
    echo "  --build-arg EXPECTED_GCC_VERSION=${EXPECTED_GCC_VERSION}"
    echo "  Context path: ${HOST_KERNEL_ROOT}"
    echo "  Dockerfile path: ${TEMP_DOCKERFILE}"

    docker build \
        --no-cache \
        --build-arg UBUNTU_VERSION="${UBUNTU_VERSION}" \
        --build-arg EXPECTED_GCC_VERSION="${EXPECTED_GCC_VERSION}" \
        -t "${DOCKER_IMAGE}" \
        -f "${TEMP_DOCKERFILE}" \
        "${HOST_KERNEL_ROOT}"

    # Remove temporary Dockerfile
    rm -f "${TEMP_DOCKERFILE}"
}

# Build Docker image
if ! docker images | grep -q "${DOCKER_IMAGE}"; then
    echo "Building Docker image..."
    # Verify build context
    if [ ! -d "${HOST_KERNEL_ROOT}" ]; then
        echo "Error: build context path not found → ${HOST_KERNEL_ROOT}"
        exit 1
    fi
    docker_build_prepare
else
    echo "Docker image exists, skipping build step"
fi

# Container kernel build
echo "Starting container kernel build"

# Temp script for container build
CONTAINER_SCRIPT=$(mktemp)
docker_run_prepare(){
    (
    run_script() {
        #!/bin/bash
        set -eE
        #trap 'echo "environment build error: line $LINENO"; exit 1' ERR

        # Container env debug
        echo "Container environment variables:"
        echo "SUITE: ${SUITE}"
        echo "KERNEL_REPO: ${KERNEL_REPO}"
        echo "KERNEL_BRANCH: ${KERNEL_BRANCH}"
        echo "KERNEL_FLAVOR: ${KERNEL_FLAVOR}"
        echo "Current directory: $(pwd)"
        echo "Directory contents: $(ls -la)"

        # Ensure gawk
        echo "Installing gawk in container"
        apt-get install -y --no-install-recommends gawk || { echo "gawk installation failed"; exit 1; }
        # Check executable presence
        if [ ! -x "/usr/bin/gawk" ]; then
            echo "Error: gawk still not found or not executable after install"
            echo "PATH: $PATH"
            ls -l /usr/bin/gawk* || true
            stat /usr/bin/gawk || true
            exit 1
        fi
        echo "Container gawk version: $(gawk --version | head -1)"
        echo "Container gawk path: $(which gawk)"
        echo "Container gawk self-test: $(echo '2+2' | gawk '{print $1}')"

        command -v modinfo || { echo "Error: modinfo (kmod) not installed"; exit 1; }  # added
        command -v depmod || { echo "Error: depmod (kmod) not installed"; exit 1; }    # added

        echo "✓ modinfo: $(which modinfo)"
        echo "✓ depmod: $(which depmod)"

        # Git clone/pull logic
        echo "Clone/update kernel source"
        mkdir -p build && cd build || { echo "Failed to enter build directory"; exit 1; }

        # Check repo accessibility
        echo "Testing repo accessibility: git ls-remote ${KERNEL_REPO} ${KERNEL_BRANCH}"
        git ls-remote "${KERNEL_REPO}" "${KERNEL_BRANCH}" || { echo "Repository/branch not accessible"; exit 1; }

        if [ -d "linux-rockchip/.git" ]; then
            echo "Source dir exists, pulling updates"
            git -C linux-rockchip pull --depth=2 || { 
                echo "Git pull failed, retrying clone"; 
                rm -rf linux-rockchip; 
            }
        fi

        if [ ! -d "linux-rockchip/.git" ]; then
            echo "Source dir missing, cloning repository"
            git clone --progress -b "${KERNEL_BRANCH}" "${KERNEL_REPO}" linux-rockchip --depth=2 || { 
                echo "Git clone failed"; 
                exit 1; 
            }
        fi

        cd linux-rockchip || { echo "Failed to enter linux-rockchip directory"; exit 1; }
        git checkout "${KERNEL_BRANCH}" || { echo "Failed to checkout branch"; exit 1; }
        echo "Current branch: $(git rev-parse --abbrev-ref HEAD)"
        echo "Latest commit: $(git log -1 --oneline)"

        # Check debian/rules
        echo "Check build config files"
        if [ ! -f "debian/rules" ]; then
            echo "Error: debian/rules not found in source directory"
            echo "Current debian dir files: $(ls -la debian/ | head -20)"
            exit 1
        fi

        # Extract kernel version
        echo "Extract kernel version"
        KERNEL_VER=$(make -s kernelversion) || { echo "Failed to extract kernel version"; exit 1; }
        echo "Kernel source version: ${KERNEL_VER}"

        # Pre-build dependency checks
        echo "Check build dependencies"
        dpkg-architecture -aarm64 || { echo "dpkg-architecture failed"; exit 1; }
        which aarch64-linux-gnu-gcc || { echo "aarch64-linux-gnu-gcc not found"; exit 1; }
        aarch64-linux-gnu-gcc --version

        # Kernel build (verbose)
        echo "Start kernel build"
        export $(dpkg-architecture -aarm64)
        export CROSS_COMPILE=aarch64-linux-gnu-
        export CC=aarch64-linux-gnu-gcc
        export LANG=C

        echo "Running: fakeroot debian/rules clean"
        fakeroot debian/rules clean 2>&1 || { echo "clean step failed"; exit 1; }

        echo "Running: fakeroot debian/rules binary-headers binary-rockchip do_mainline_build=true"
        fakeroot debian/rules binary-headers binary-rockchip do_mainline_build=true MAKEFLAGS="-j$(nproc)" 2>&1 || { 
            echo "Kernel build failed"; 
            exit 1; 
        }

        # Print kernel version
        echo "Build complete, kernel version"
        echo "${KERNEL_VER}"
    }

    SUBSTITUTED_SCRIPT=$(type run_script | extract_body) 
    FINAL_SCRIPT="${SUBSTITUTED_SCRIPT}"
    printf '%s' "$FINAL_SCRIPT" > "${CONTAINER_SCRIPT}"
    )

    # Run container build
    docker run --rm -i \
        --privileged \
        -e SUITE="${SUITE}" \
        -e RELEASE_VERSION="${UBUNTU_VERSION}" \
        -e KERNEL_REPO="${KERNEL_REPO}" \
        -e KERNEL_BRANCH="${KERNEL_BRANCH}" \
        -e KERNEL_FLAVOR="${KERNEL_FLAVOR}" \
        -v "${HOST_KERNEL_ROOT}:/kernel-build" \
        -v "${CONTAINER_SCRIPT}:/container-script.sh:ro" \
        -w /kernel-build \
        "${DOCKER_IMAGE}" \
        /bin/bash /container-script.sh | tee /tmp/kernel-build-container.log
    
        # Clean up container script
        rm -f "${CONTAINER_SCRIPT}"
}

docker_run_prepare

# Capture kernel version & cleanup
KERNEL_VERSION=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+" /tmp/kernel-build-container.log | tail -1)
rm -f "${CONTAINER_SCRIPT}" /tmp/kernel-build-container.log

# Verify kernel version
if [ -z "${KERNEL_VERSION}" ]; then
    echo "Error: kernel version not found; build may have failed"
    exit 1
fi

# Build summary
echo -e "\nKernel build finished 🚀"
echo "│ Ubuntu version:  ${UBUNTU_VERSION}"
echo "│ GCC build version:  ${EXPECTED_GCC_VERSION}"
echo "│ Kernel source version:  ${KERNEL_VERSION}"
echo "│ Kernel branch:  ${KERNEL_BRANCH}"
echo "│ Artifacts path:  ${HOST_KERNEL_ROOT}/build/"
