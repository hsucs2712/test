#!/bin/bash
#===============================================================================
# 01_setup_mdadm.sh
# mdadm RAID 設定腳本（RAID5, RAID6, RAID10）
#===============================================================================

set -e

# 設定變數 - 根據實際環境修改
DISKS=("/dev/nvme1n1" "/dev/nvme3n1" "/dev/nvme4n1" "/dev/nvme5n1")  # NVMe 硬碟
TEST_BASE="/mnt/mdadm_test"

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
    
    # 檢查 root 權限
    if [[ $EUID -ne 0 ]]; then
        log_error "請使用 root 權限執行"
        exit 1
    fi
    
    # 檢查 mdadm
    if ! command -v mdadm &> /dev/null; then
        log_info "安裝 mdadm..."
        apt update && apt install -y mdadm
    fi
    
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
# 清理現有 RAID
#-------------------------------------------------------------------------------
cleanup_mdadm() {
    log_info "清理現有 mdadm 配置..."
    
    # 停止並移除現有陣列
    for md in /dev/md*; do
        if [[ -b "$md" ]]; then
            umount "$md" 2>/dev/null || true
            mdadm --stop "$md" 2>/dev/null || true
        fi
    done
    
    # 清除硬碟上的 superblock
    for disk in "${DISKS[@]}"; do
        mdadm --zero-superblock "$disk" 2>/dev/null || true
        wipefs -a "$disk" 2>/dev/null || true
    done
    
    # 移除掛載目錄
    rm -rf "$TEST_BASE"
    
    log_info "清理完成"
}

#-------------------------------------------------------------------------------
# 建立 RAID5 (3+1 parity)
#-------------------------------------------------------------------------------
create_raid5() {
    local md_device="/dev/md5"
    local mount_point="$TEST_BASE/raid5"
    
    log_info "建立 RAID5..."
    
    # 建立 RAID5
    mdadm --create "$md_device" \
        --level=5 \
        --raid-devices=4 \
        "${DISKS[@]}" \
        --run
    
    # 等待初始化
    log_info "等待 RAID5 同步..."
    while grep -q "resync" /proc/mdstat; do
        sleep 5
        cat /proc/mdstat | grep -A1 md5 || true
    done
    
    # 格式化
    mkfs.ext4 -F "$md_device"
    
    # 掛載
    mkdir -p "$mount_point"
    mount "$md_device" "$mount_point"
    
    log_info "RAID5 建立完成: $mount_point"
}

#-------------------------------------------------------------------------------
# 建立 RAID6 (2+2 parity)
#-------------------------------------------------------------------------------
create_raid6() {
    local md_device="/dev/md6"
    local mount_point="$TEST_BASE/raid6"
    
    log_info "建立 RAID6..."
    
    mdadm --create "$md_device" \
        --level=6 \
        --raid-devices=4 \
        "${DISKS[@]}" \
        --run
    
    log_info "等待 RAID6 同步..."
    while grep -q "resync" /proc/mdstat; do
        sleep 5
        cat /proc/mdstat | grep -A1 md6 || true
    done
    
    mkfs.ext4 -F "$md_device"
    
    mkdir -p "$mount_point"
    mount "$md_device" "$mount_point"
    
    log_info "RAID6 建立完成: $mount_point"
}

#-------------------------------------------------------------------------------
# 建立 RAID10
#-------------------------------------------------------------------------------
create_raid10() {
    local md_device="/dev/md10"
    local mount_point="$TEST_BASE/raid10"
    
    log_info "建立 RAID10..."
    
    mdadm --create "$md_device" \
        --level=10 \
        --raid-devices=4 \
        "${DISKS[@]}" \
        --run
    
    log_info "等待 RAID10 同步..."
    while grep -q "resync" /proc/mdstat; do
        sleep 5
        cat /proc/mdstat | grep -A1 md10 || true
    done
    
    mkfs.ext4 -F "$md_device"
    
    mkdir -p "$mount_point"
    mount "$md_device" "$mount_point"
    
    log_info "RAID10 建立完成: $mount_point"
}

#-------------------------------------------------------------------------------
# 儲存配置
#-------------------------------------------------------------------------------
save_config() {
    log_info "儲存 mdadm 配置..."
    
    mdadm --detail --scan >> /etc/mdadm/mdadm.conf
    update-initramfs -u
    
    log_info "配置已儲存"
}

#-------------------------------------------------------------------------------
# 顯示狀態
#-------------------------------------------------------------------------------
show_status() {
    echo ""
    echo "=============================================="
    echo "mdadm RAID 狀態"
    echo "=============================================="
    cat /proc/mdstat
    echo ""
    echo "掛載點:"
    df -h | grep mdadm_test || true
    echo "=============================================="
}

#-------------------------------------------------------------------------------
# 主程式
#-------------------------------------------------------------------------------
main() {
    local action="${1:-all}"
    
    case "$action" in
        raid5)
            check_prerequisites
            cleanup_mdadm
            create_raid5
            ;;
        raid6)
            check_prerequisites
            cleanup_mdadm
            create_raid6
            ;;
        raid10)
            check_prerequisites
            cleanup_mdadm
            create_raid10
            ;;
        all)
            check_prerequisites
            cleanup_mdadm
            # 注意：一次只能建一個，因為用相同的硬碟
            log_warn "將依序建立 RAID5, RAID6, RAID10 進行測試"
            log_warn "每次測試完成後會清理並建立下一個"
            ;;
        cleanup)
            cleanup_mdadm
            ;;
        status)
            show_status
            ;;
        *)
            echo "用法: $0 {raid5|raid6|raid10|all|cleanup|status}"
            exit 1
            ;;
    esac
    
    show_status
}

main "$@"
