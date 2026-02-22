#!/bin/bash

#set -eE 
#trap 'echo Error: in $0 on line $LINENO' ERR
#exec 2> /dev/tty

cd "$(dirname -- "$(readlink -f -- "$0")")"

extract_body() {
    perl -0777 -ne 'while (/\b(?:function\s+)?([A-Za-z_]\w*)\s*\(\s*\)\s*(\{(?:[^{}]++|(?2))*\})/g) { my $c = substr($2,1,-1); $c =~ s/^[ \t\r\n]+//; $c =~ s/[ \t\r\n]+$//; # remove semicolons before [...]
$c =~ s/;[ \t]*(?=\n)//g; $c =~ s/;[ \t]*\z//; # collapse multiple blank lines
$c =~ s/\n[ \t]*\n+/\n/g; print "$c\n" }' "$@"
}

export -f extract_body

info() {
    printf '\033[1;32m[INFO]\033[0m %s\n' "$*"
}
warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*"
}
error() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
}

export -f info warn error

usage() {
cat << HEREDOC
Usage: $0 --board=[orangepi-5] --suite=[jammy|noble] --flavor=[server|desktop]

Required arguments:
  -b, --board=BOARD      target board 
  -s, --suite=SUITE      ubuntu suite 
  -f, --flavor=FLAVOR    ubuntu flavor

Optional arguments:
  -h,  --help            show this help message and exit
  -c,  --clean           clean the build directory
  -ko, --kernel-only     only compile the kernel
  -uo, --uboot-only      only compile uboot
  -ro, --rootfs-only     only build rootfs
  -l,  --launchpad       use kernel and uboot from launchpad repo
  -v,  --verbose         increase the verbosity of the bash script
HEREDOC
}

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")"

while [ "$#" -gt 0 ]; do
    case "${1}" in
        -h|--help)
            usage
            exit 0
            ;;
        -b=*|--board=*)
            export BOARD="${1#*=}"
            shift
            ;;
        -b|--board)
            export BOARD="${2}"
            shift 2
            ;;
        -s=*|--suite=*)
            export SUITE="${1#*=}"
            shift
            ;;
        -s|--suite)
            export SUITE="${2}"
            shift 2
            ;;
        -f=*|--flavor=*)
            export FLAVOR="${1#*=}"
            shift
            ;;
        -f|--flavor)
            export FLAVOR="${2}"
            shift 2
            ;;
        -ko|--kernel-only)
            export KERNEL_ONLY=Y
            shift
            ;;
        -uo|--uboot-only)
            export UBOOT_ONLY=Y
            shift
            ;;
        -ro|--rootfs-only)
            export ROOTFS_ONLY=Y
            shift
            ;;
        -l|--launchpad)
            export LAUNCHPAD=Y
            shift
            ;;
        -c|--clean)
            export CLEAN=Y
            shift
            ;;
        -v|--verbose)
            set -x
            shift
            ;;
        -*)
            echo "Error: unknown argument \"${1}\""
            exit 1
            ;;
        *)
            shift
            ;;
    esac
done

if [ "${SUITE}" == "help" ]; then
    for file in config/suites/*; do
        basename "${file%.sh}"
    done
    exit 0
fi

if [ -n "${SUITE}" ]; then
    while :; do
        for file in config/suites/*; do
            if [ "${SUITE}" == "$(basename "${file%.sh}")" ]; then
                # shellcheck source=/dev/null
                source "${file}"
                break 2
            fi
        done
        echo "Error: \"${SUITE}\" is an unsupported suite"
        exit 1
    done
fi

if [ "${FLAVOR}" == "help" ]; then
    for file in config/flavors/*; do
        basename "${file%.sh}"
    done
    exit 0
fi

if [ -n "${FLAVOR}" ]; then
    while :; do
        for file in config/flavors/*; do
            if [ "${FLAVOR}" == "$(basename "${file%.sh}")" ]; then
                # shellcheck source=/dev/null
                source "${file}"
                break 2
            fi
        done
        echo "Error: \"${FLAVOR}\" is an unsupported flavor"
        exit 1
    done
fi

if [ "${BOARD}" == "help" ]; then
    for file in config/boards/*; do
        basename "${file%.sh}"
    done
    exit 0
fi

if [ -n "${BOARD}" ]; then
    while :; do
        for file in config/boards/*; do
            if [ "${BOARD}" == "$(basename "${file%.sh}")" ]; then
                # shellcheck source=/dev/null
                source "${file}"
                break 2
            fi
        done
        echo "Error: \"${BOARD}\" is an unsupported board"
        exit 1
    done
fi

if [ "${CLEAN}" == "Y" ]; then
    if [ -d build/rootfs ]; then
        umount -lf build/rootfs/dev/pts 2> /dev/null || true
        umount -lf build/rootfs/* 2> /dev/null || true
    fi
    rm -rf build
fi


mkdir -p build/logs
LOG_DIR="build/logs"
LOG_FILE="$LOG_DIR/build-$(date +"%Y%m%d%H%M%S").log"

# 检查环境变量。如果没有这个变量，说明这是第一次启动，需要开启记录
if [[ -z "${INSIDE_SCRIPT:-}" && -z "${SCRIPT:-}" ]]; then
    # 只有在完全没有录制环境时，才开启内部录制
    mkdir -p "$LOG_DIR"
    export INSIDE_SCRIPT=1
    
    # 用 -q 配合简单的重定向，避开那两行讨厌的 Header
    # 既然 -q 在你的环境下日志里还有，那我们直接不让 script 写文件，我们自己用 tee 拿
    exec script -qec "$0 $*" /dev/null | stdbuf -oL tee -a "$LOG_FILE"
    exit $?
fi

#mkdir -p build/logs && exec > >(tee "build/logs/build-$(date +"%Y%m%d%H%M%S").log") 2>&1

#bash -x ./scripts/config-image.sh
#exit 0

if [ "${KERNEL_ONLY}" == "Y" ]; then
    if [ -z "${SUITE}" ]; then
        usage
        exit 1
    fi
    ./scripts/build-kernel.sh
    exit 0
fi

if [ "${ROOTFS_ONLY}" == "Y" ]; then
    if [ -z "${SUITE}" ] || [ -z "${FLAVOR}" ]; then
        usage
        exit 1
    fi
    ./scripts/build-rootfs.sh
    exit 0
fi

if [ "${UBOOT_ONLY}" == "Y" ]; then
    if [ -z "${BOARD}" ]; then
        usage
        exit 1
    fi
    ./scripts/build-u-boot.sh
    exit 0
fi

# No board param passed
if [ -z "${BOARD}" ] || [ -z "${SUITE}" ] || [ -z "${FLAVOR}" ]; then
    usage
    exit 1
fi

# Build the Linux kernel if not found
if [[ ${LAUNCHPAD} != "Y" ]]; then
    if [[ ! -e "$(find build/linux-image-*.deb | sort | tail -n1)" || ! -e "$(find build/linux-headers-*.deb | sort | tail -n1)" ]]; then
        ./scripts/build-kernel.sh
    fi
fi

# Build U-Boot if not found
if [[ ${LAUNCHPAD} != "Y" ]]; then
    if [[ ! -e "$(find build/u-boot-"${BOARD}"_*.deb | sort | tail -n1)" ]]; then
        ./scripts/build-u-boot.sh
    fi
fi

# Create the root filesystem
bash -x ./scripts/build-rootfs.sh

# Create the disk image
bash -x ./scripts/config-image.sh

exit 0
