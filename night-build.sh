#!/bin/bash
set -euo pipefail
#trap 'echo "Error at line $LINENO: $BASH_COMMAND"' ERR

# ========================= 全局配置（可根据本地环境修改）=========================
export REPO_OWNER="sfqr0414"
export REPO_NAME=ubuntu-rockchip
export RELEASE_TAG=workflow
export ROOTFS_FILE_PREFIX=ubuntu
export ROOTFS_ARCH=arm64
export WORKSPACE=$(pwd)
export CACHE_DIR="${WORKSPACE}/cache"
export BUILD_DIR="${WORKSPACE}/build"
export IMAGES_DIR="${WORKSPACE}/images"
export RELEASES_DIR="${WORKSPACE}/releases"
export LOGS_DIR="${WORKSPACE}/logs"

# GitHub Release Asset检查基础URL
export GITHUB_RELEASE_DOWNLOAD_BASE="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${RELEASE_TAG}"

# ========================= 工具函数 =========================
# 磁盘清理函数（保留build目录下的有效文件，仅清理临时/无用文件）
clean_disk_space() {
    echo -e "\n===== 清理磁盘空间 ====="
    # 仅清理系统临时文件，不删除build目录下的有效文件
    sudo rm -rf /tmp/* /var/tmp/* || true
    if command -v docker &> /dev/null; then
        sudo docker system prune -a -f || true
    fi
    sudo apt-get clean || true
    sudo apt-get autoremove -y --purge || true
    # 仅清理images目录（镜像产物），保留build目录的rootfs/deb文件
    sudo rm -rf "${IMAGES_DIR:?}"/* || true
    # 释放内存缓存
    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches || true
    # 显示磁盘状态
    echo -e "\n===== 磁盘空间状态 ====="
    df -h
}

# 检查本地文件是否存在且有效（大小>0）
check_local_file_exists() {
    local file_path="$1"
    if [ -f "${file_path}" ] && [ -s "${file_path}" ]; then
        echo "true"
        return 0
    else
        echo "false"
        return 1
    fi
}

# 检查远程Asset是否存在（处理GitHub 302重定向）
check_remote_asset_exists() {
    local asset_name="$1"
    local download_url="${GITHUB_RELEASE_DOWNLOAD_BASE}/${asset_name}"
    
    # -L：跟随重定向；-s：静默模式；-o /dev/null：丢弃响应体；-w：输出状态码；--max-time：超时10秒
    local http_code=$(curl -L -s -o /dev/null -w "%{http_code}" --max-time 10 "${download_url}")
    # GitHub资产存在：最终状态码为200；不存在：404；权限问题：403（也视为存在）
    if [ "${http_code}" = "200" ] || [ "${http_code}" = "403" ]; then
        echo "true"
        return 0
    else
        echo "false"
        return 1
    fi
}

# 下载远程Asset（取消静默模式，保留下载进度输出）
download_remote_asset() {
    local asset_name="$1"
    local save_path="$2"
    local download_url="${GITHUB_RELEASE_DOWNLOAD_BASE}/${asset_name}"
    local save_dir=$(dirname "${save_path}")
    
    echo "开始下载远程文件：${asset_name}"
    # 1. 确保保存目录存在且有写入权限
    sudo mkdir -p "${save_dir}"
    sudo chmod 777 "${save_dir}"
    
    # 2. 取消-q（静默模式），保留下载进度输出；-L：跟随重定向；-T：超时300秒；-O：输出到指定文件
    sudo wget -L -T 300 -O "${save_path}" "${download_url}" || {
        echo "下载失败：${download_url}"
        sudo rm -f "${save_path}"  # 清理失败的空文件
        return 1
    }
    
    # 3. 验证文件是否下载成功（大小>0）
    if [ ! -s "${save_path}" ]; then
        echo "下载的文件为空：${save_path}"
        sudo rm -f "${save_path}"
        return 1
    fi
    
    # 4. 修复下载文件的权限（方便后续使用）
    sudo chmod 644 "${save_path}"
    echo "下载完成：${save_path}"
    return 0
}

# 生成构建矩阵
generate_matrices() {
    echo -e "\n===== 生成RootFS构建矩阵 ====="
    ROOTFS_MATRIX=()
    for suite in "${WORKSPACE}/config/suites"/*.sh; do
        [ -f "$suite" ] || continue
        suite_name=$(basename "${suite%.sh}")
        for flavor in "${WORKSPACE}/config/flavors"/*.sh; do
            [ -f "$flavor" ] || continue
            flavor_name=$(basename "${flavor%.sh}")
            ROOTFS_MATRIX+=("${suite_name}|${flavor_name}")
            echo "RootFS任务：suite=${suite_name}, flavor=${flavor_name}"
        done
    done

    echo -e "\n===== 生成镜像构建矩阵 ====="
    BUILD_MATRIX=()
    for board in "${WORKSPACE}/config/boards"/*.sh; do
        [ -f "$board" ] || continue
        board_name=$(basename "${board%.sh}")
        COMPATIBLE_SUITES=()
        COMPATIBLE_FLAVORS=()
        source "$board" || { echo "加载board配置失败：$board"; exit 1; }
        for suite in "${COMPATIBLE_SUITES[@]}"; do
            for flavor in "${COMPATIBLE_FLAVORS[@]}"; do
                BUILD_MATRIX+=("${board_name}|${suite}|${flavor}")
                echo "镜像任务：board=${board_name}, suite=${suite}, flavor=${flavor}"
            done
        done
    done

    export ROOTFS_MATRIX
    export BUILD_MATRIX
}

# ========================= RootFS构建函数（本地文件优先）=========================
build_rootfs() {
    local suite="$1"
    local flavor="$2"
    echo -e "\n===== 开始构建RootFS：${suite}-${flavor} =====\n"

    # 1. 前置清理（保留build目录有效文件）
    clean_disk_space

    # 2. 加载suite配置
    source "${WORKSPACE}/config/suites/${suite}.sh" || { echo "加载suite配置失败"; exit 1; }
    local suite_version="${RELEASE_VERSION}"
    local rootfs_zip_name="${ROOTFS_FILE_PREFIX}-${suite_version}-preinstalled-${flavor}-${ROOTFS_ARCH}-rootfs.zip"
    local rootfs_tar_name="${ROOTFS_FILE_PREFIX}-${suite_version}-preinstalled-${flavor}-${ROOTFS_ARCH}.rootfs.tar.xz"
    local rootfs_zip_path="${BUILD_DIR}/${rootfs_zip_name}"
    local rootfs_tar_path="${BUILD_DIR}/${rootfs_tar_name}"

    # 3. 优先检查本地是否有已解压的tar文件（最终产物）
    local local_tar_exists=$(check_local_file_exists "${rootfs_tar_path}")
    if [ "${local_tar_exists}" = "true" ]; then
        echo "本地已存在RootFS tar文件：${rootfs_tar_path}，直接复用"
        remote_exists="false"
    else
        # 4. 检查本地是否有zip文件，有则尝试解压
        local local_zip_exists=$(check_local_file_exists "${rootfs_zip_path}")
        if [ "${local_zip_exists}" = "true" ]; then
            echo "本地已存在RootFS zip文件：${rootfs_zip_path}，尝试解压"
            sudo unzip -o "${rootfs_zip_path}" -d "${BUILD_DIR}" || {
                echo "本地zip文件解压失败，删除损坏文件并尝试远程下载"
                sudo rm -f "${rootfs_zip_path}"
                local_zip_exists="false"
            }
            # 解压后再次检查tar文件
            local_tar_exists=$(check_local_file_exists "${rootfs_tar_path}")
            if [ "${local_tar_exists}" = "true" ]; then
                echo "本地zip解压成功，复用RootFS tar文件"
                remote_exists="false"
            fi
        fi

        # 5. 本地无有效文件，检查远程并下载
        if [ "${local_tar_exists}" = "false" ]; then
            local remote_exists=$(check_remote_asset_exists "${rootfs_zip_name}")
            if [ "${remote_exists}" = "true" ]; then
                # 下载远程zip并解压
                if download_remote_asset "${rootfs_zip_name}" "${rootfs_zip_path}"; then
                    sudo unzip -o "${rootfs_zip_path}" -d "${BUILD_DIR}" || {
                        echo "远程zip解压失败，切换为本地构建"
                        remote_exists="false"
                    }
                    # 验证解压后的tar文件
                    local_tar_exists=$(check_local_file_exists "${rootfs_tar_path}")
                    if [ "${local_tar_exists}" != "true" ]; then
                        echo "远程zip解压后无有效tar文件，切换为本地构建"
                        remote_exists="false"
                    fi
                else
                    echo "远程RootFS下载失败，切换为本地构建"
                    remote_exists="false"
                fi
            else
                echo "远程无RootFS文件，执行本地构建"
                remote_exists="false"
            fi
        fi
    fi

    # 6. 本地构建RootFS（仅当本地/远程都无有效文件时）
    if [ "${local_tar_exists}" != "true" ] && [ "${remote_exists}" = "false" ]; then
        echo -e "\n===== 本地构建RootFS：${suite}-${flavor} ====="
        # 安装依赖
        sudo apt-get update && sudo apt-get upgrade -y
        sudo apt-get install -y \
            build-essential gcc-aarch64-linux-gnu bison \
            qemu-user-static qemu-system-arm qemu-efi u-boot-tools binfmt-support \
            debootstrap flex libssl-dev bc rsync kmod cpio xz-utils fakeroot parted \
            udev dosfstools uuid-runtime git-lfs device-tree-compiler python2 python3 \
            python-is-python3 fdisk bc debhelper python3-pyelftools python3-setuptools \
            python3-distutils python3-pkg-resources swig libfdt-dev libpython3-dev dctrl-tools \
            opencl-c-headers ocl-icd-opencl-dev dmraid libgpgme11-dev \
            live-build ubuntu-keyring \
            gcc-aarch64-linux-gnu
        sudo update-binfmts --enable qemu-aarch64

        # 添加执行权限
        chmod +x "${WORKSPACE}/build.sh"
        chmod +x "${WORKSPACE}/scripts"/*.sh

        # 创建目录
        sudo mkdir -p "${BUILD_DIR}/chroot/etc/default"
        sudo mkdir -p "${BUILD_DIR}/rootfs/dev"
        sudo chmod 777 -R "${BUILD_DIR}/chroot"
        sudo chmod 777 -R "${BUILD_DIR}/rootfs"

        # 执行构建
        cd "${WORKSPACE}"
        sudo bash ./build.sh --suite="${suite}" --flavor="${flavor}" --rootfs-only 2>&1 | tee "${LOGS_DIR}/rootfs-build-${suite}-${flavor}.log"

        # 检查产物
        if [ ! -f "${rootfs_tar_path}" ]; then
            echo "RootFS构建失败：未找到产物 ${rootfs_tar_path}"
            exit 1
        fi
    fi

    # 7. 缓存RootFS到cache目录
    echo -e "\n===== 缓存RootFS到本地 ====="
    sudo mkdir -p "${CACHE_DIR}/rootfs"
    if [ -f "${CACHE_DIR}/rootfs/${rootfs_tar_name}" ]; then
        echo "RootFS已在缓存目录，无需复制：${rootfs_tar_path}"
    else   
        sudo cp "${rootfs_tar_path}" "${CACHE_DIR}/rootfs/"
        sudo chmod 644 "${CACHE_DIR}/rootfs/${rootfs_tar_name}"
        echo "RootFS缓存完成：${CACHE_DIR}/rootfs/${rootfs_tar_name}"
    fi
}

# ========================= 镜像构建函数（本地文件优先）=========================
build_image() {
    local board="$1"
    local suite="$2"
    local flavor="$3"
    echo -e "\n===== 开始构建镜像：${board}-${suite}-${flavor} =====\n"

    # 1. 前置清理
    clean_disk_space

    # 2. 加载suite配置
    source "${WORKSPACE}/config/suites/${suite}.sh" || { echo "加载suite配置失败"; exit 1; }
    local suite_version="${RELEASE_VERSION}"
    local rootfs_tar_name="${ROOTFS_FILE_PREFIX}-${suite_version}-preinstalled-${flavor}-${ROOTFS_ARCH}.rootfs.tar.xz"
    local rootfs_tar_path="${CACHE_DIR}/rootfs/${rootfs_tar_name}"

    # 3. 检查RootFS缓存
    local rootfs_cache_exists=$(check_local_file_exists "${rootfs_tar_path}")
    if [ "${rootfs_cache_exists}" != "true" ]; then
        echo "RootFS缓存不存在，请先构建RootFS：${rootfs_tar_path}"
        exit 1
    fi
    sudo mkdir -p "${BUILD_DIR}"
    sudo cp "${rootfs_tar_path}" "${BUILD_DIR}/"
    sudo chmod 644 "${BUILD_DIR}/${rootfs_tar_name}"

    # 4. 优先检查本地DEB包
    local deb_zip_name="deb-packages-${board}-${suite}.zip"
    local deb_zip_path="${BUILD_DIR}/${deb_zip_name}"
    local local_deb_zip_exists=$(check_local_file_exists "${deb_zip_path}")
    local deb_remote_exists="false"

    if [ "${local_deb_zip_exists}" = "true" ]; then
        echo "本地已存在DEB zip文件：${deb_zip_path}，尝试解压"
        sudo unzip -o "${deb_zip_path}" -d "${BUILD_DIR}" || {
            echo "本地DEB zip解压失败，删除损坏文件并尝试远程下载"
            sudo rm -f "${deb_zip_path}"
            local_deb_zip_exists="false"
        }
    fi

    # 5. 本地无DEB包，检查远程并下载
    if [ "${local_deb_zip_exists}" != "true" ]; then
        deb_remote_exists=$(check_remote_asset_exists "${deb_zip_name}")
        if [ "${deb_remote_exists}" = "true" ]; then
            if download_remote_asset "${deb_zip_name}" "${deb_zip_path}"; then
                sudo unzip -o "${deb_zip_path}" -d "${BUILD_DIR}" || {
                    echo "远程DEB包解压失败，忽略DEB包复用"
                    deb_remote_exists="false"
                }
            else
                echo "远程DEB包下载失败，忽略DEB包复用"
                deb_remote_exists="false"
            fi
        fi
    fi

    # 6. 安装镜像构建依赖
    echo -e "\n===== 安装镜像构建依赖 ====="
    sudo apt-get update && sudo apt-get upgrade -y
    sudo apt-get install -y \
        build-essential device-tree-compiler u-boot-tools \
        qemu-user-static binfmt-support debootstrap \
        fdisk parted dosfstools uuid-runtime rsync kmod \
        gcc-aarch64-linux-gnu

    # 7. 创建目录
    sudo mkdir -p "${IMAGES_DIR}"
    sudo mkdir -p "${BUILD_DIR}/chroot/etc/default"
    sudo mkdir -p "${BUILD_DIR}/rootfs/dev"
    sudo chmod 777 -R "${BUILD_DIR}/chroot"
    sudo chmod 777 -R "${BUILD_DIR}/rootfs"

    # 8. 构建镜像
    echo -e "\n===== 构建镜像：${board}-${suite}-${flavor} ====="
    cd "${WORKSPACE}"
    sudo script -eqc "bash -x ./build.sh --board='${board}' --suite='${suite}' --flavor='${flavor}'" /dev/null 2>&1 | tee "${LOGS_DIR}/image-build-${board}-${suite}-${flavor}.log"
    #sudo script -qc "bash -x ./build.sh --board=${board} --suite=${suite} --flavor=${flavor}" "${LOGS_DIR}/image-build-${board}-${suite}-${flavor}.log"
    # 9. 打包DEB包（仅当本地/远程都无有效DEB包时）
    if [ "${local_deb_zip_exists}" != "true" ] && [ "${deb_remote_exists}" = "false" ]; then
        echo -e "\n===== 打包DEB包（本地留存） ====="
        sudo mkdir -p "${RELEASES_DIR}"
        cd "${BUILD_DIR}"
        if ls ./*.deb 1> /dev/null 2>&1; then
            sudo zip "${RELEASES_DIR}/${deb_zip_name}" ./*.deb
            echo "DEB包打包完成（本地留存）：${RELEASES_DIR}/${deb_zip_name}"
        else
            echo "无DEB包需要打包"
        fi
    fi

    # 10. 检查镜像产物
    echo -e "\n===== 镜像构建完成，产物列表 ====="
    ls -la "${IMAGES_DIR}/" || echo "镜像目录不存在"
}

# ========================= 主执行逻辑 =========================
main() {
    # 创建必要目录（加sudo确保权限）
    sudo mkdir -p "${CACHE_DIR}" "${BUILD_DIR}" "${IMAGES_DIR}" "${RELEASES_DIR}" "${LOGS_DIR}"
    sudo chmod 777 -R "${CACHE_DIR}" "${BUILD_DIR}" "${IMAGES_DIR}" "${RELEASES_DIR}" "${LOGS_DIR}"

    # 生成构建矩阵
    generate_matrices

    # 构建所有RootFS
    echo -e "\n====================================="
    echo "开始批量构建RootFS"
    echo "====================================="
    for item in "${ROOTFS_MATRIX[@]}"; do
        IFS="|" read -r suite flavor <<< "$item"
        build_rootfs "${suite}" "${flavor}"
    done

    # 构建所有镜像
    echo -e "\n====================================="
    echo "开始批量构建镜像"
    echo "====================================="
    for item in "${BUILD_MATRIX[@]}"; do
        IFS="|" read -r board suite flavor <<< "$item"
        build_image "${board}" "${suite}" "${flavor}"
    done

    echo -e "\n===== 所有构建任务完成 ====="
    echo "日志目录：${LOGS_DIR}"
    echo "镜像产物：${IMAGES_DIR}"
    echo "缓存目录：${CACHE_DIR}"
    echo "DEB包目录：${RELEASES_DIR}"
}

# 执行主函数
main "$@"
