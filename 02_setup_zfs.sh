#!/bin/bash
#===============================================================================
# 02_setup_zfs.sh
# ZFS Pool 設定腳本（RAIDZ1, RAIDZ2, Mirror）
#===============================================================================

set -e

# 設定變數 - 根據實際環境修改
DISKS=("/dev/sdb" "/dev/sdc" "/dev/sdd" "/dev/sde")
POOL_NAME="testpool"
TEST_BASE="/mnt/zfs_test"

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

#-------------------------------------------------------------------------------
# 前置檢查
#-------------------------------------------------------------------------------
check_prerequisites() {
    log_info "前置檢查..."
    
    if [[ $EUID -ne 0 ]]; then
        log_error "請使用 root 權限執行"
        exit 1
    fi
    
    # 檢查 ZFS
    if ! command -v zpool &> /dev/null; then
        log_info "安裝 ZFS..."
        apt update && apt install -y zfsutils-linux
    fi
    
    # 載入 ZFS 模組
    modprobe zfs 2>/dev/null || true
    
    # 檢查硬碟存在
    for disk in "${DISKS[@]}"; do
        if [[ ! -b "$disk" ]]; then
            log_error "硬碟 $disk 不存在"
            exit 1
        fi
    done
    
    log_info "前置檢查完成"
}

#-------------------------------------------------------------------------------
# 清理現有 ZFS
#-------------------------------------------------------------------------------
cleanup_zfs() {
    log_info "清理現有 ZFS 配置..."
    
    # 銷毀現有 pool
    zpool destroy "$POOL_NAME" 2>/dev/null || true
    zpool destroy "${POOL_NAME}_raidz1" 2>/dev/null || true
    zpool destroy "${POOL_NAME}_raidz2" 2>/dev/null || true
    zpool destroy "${POOL_NAME}_mirror" 2>/dev/null || true
    
    # 清除硬碟標籤
    for disk in "${DISKS[@]}"; do
        zpool labelclear -f "$disk" 2>/dev/null || true
        wipefs -a "$disk" 2>/dev/null || true
    done
    
    rm -rf "$TEST_BASE"
    
    log_info "清理完成"
}

#-------------------------------------------------------------------------------
# 建立 RAIDZ1 (類似 RAID5)
#-------------------------------------------------------------------------------
create_raidz1() {
    local pool="${POOL_NAME}_raidz1"
    local mount_point="$TEST_BASE/raidz1"
    
    log_info "建立 RAIDZ1 pool..."
    
    mkdir -p "$mount_point"
    
    zpool create -f \
        -o ashift=12 \
        -O mountpoint="$mount_point" \
        -O atime=off \
        -O compression=off \
        -O checksum=on \
        "$pool" raidz1 "${DISKS[@]}"
    
    log_info "RAIDZ1 建立完成: $mount_point"
    zpool status "$pool"
}

#-------------------------------------------------------------------------------
# 建立 RAIDZ2 (類似 RAID6)
#-------------------------------------------------------------------------------
create_raidz2() {
    local pool="${POOL_NAME}_raidz2"
    local mount_point="$TEST_BASE/raidz2"
    
    log_info "建立 RAIDZ2 pool..."
    
    mkdir -p "$mount_point"
    
    zpool create -f \
        -o ashift=12 \
        -O mountpoint="$mount_point" \
        -O atime=off \
        -O compression=off \
        -O checksum=on \
        "$pool" raidz2 "${DISKS[@]}"
    
    log_info "RAIDZ2 建立完成: $mount_point"
    zpool status "$pool"
}

#-------------------------------------------------------------------------------
# 建立 Mirror (類似 RAID10)
#-------------------------------------------------------------------------------
create_mirror() {
    local pool="${POOL_NAME}_mirror"
    local mount_point="$TEST_BASE/mirror"
    
    log_info "建立 Mirror (striped mirrors) pool..."
    
    mkdir -p "$mount_point"
    
    # 2組 mirror stripe (類似 RAID10)
    zpool create -f \
        -o ashift=12 \
        -O mountpoint="$mount_point" \
        -O atime=off \
        -O compression=off \
        -O checksum=on \
        "$pool" \
        mirror "${DISKS[0]}" "${DISKS[1]}" \
        mirror "${DISKS[2]}" "${DISKS[3]}"
    
    log_info "Mirror 建立完成: $mount_point"
    zpool status "$pool"
}

#-------------------------------------------------------------------------------
# 設定不同 recordsize 的 dataset
#-------------------------------------------------------------------------------
create_datasets() {
    local pool="$1"
    
    log_info "建立不同 recordsize 的 dataset..."
    
    # 128K recordsize (預設)
    zfs create -o recordsize=128K "$pool/rs128k"
    
    # 1M recordsize (大檔案優化)
    zfs create -o recordsize=1M "$pool/rs1m"
    
    # 4K recordsize (小檔案/資料庫)
    zfs create -o recordsize=4K "$pool/rs4k"
    
    zfs list -r "$pool"
}

#-------------------------------------------------------------------------------
# 顯示狀態
#-------------------------------------------------------------------------------
show_status() {
    echo ""
    echo "=============================================="
    echo "ZFS Pool 狀態"
    echo "=============================================="
    zpool list 2>/dev/null || echo "無 ZFS pool"
    echo ""
    zpool status 2>/dev/null || true
    echo ""
    echo "Dataset:"
    zfs list 2>/dev/null || true
    echo "=============================================="
}

#-------------------------------------------------------------------------------
# 主程式
#-------------------------------------------------------------------------------
main() {
    local action="${1:-all}"
    
    case "$action" in
        raidz1)
            check_prerequisites
            cleanup_zfs
            create_raidz1
            create_datasets "${POOL_NAME}_raidz1"
            ;;
        raidz2)
            check_prerequisites
            cleanup_zfs
            create_raidz2
            create_datasets "${POOL_NAME}_raidz2"
            ;;
        mirror)
            check_prerequisites
            cleanup_zfs
            create_mirror
            create_datasets "${POOL_NAME}_mirror"
            ;;
        all)
            check_prerequisites
            cleanup_zfs
            log_warn "將依序建立 RAIDZ1, RAIDZ2, Mirror 進行測試"
            ;;
        cleanup)
            cleanup_zfs
            ;;
        status)
            show_status
            ;;
        *)
            echo "用法: $0 {raidz1|raidz2|mirror|all|cleanup|status}"
            exit 1
            ;;
    esac
    
    show_status
}

main "$@"
