#!/bin/bash
#===============================================================================
# run_all_tests.sh
# mdadm vs ZFS 完整比較測試 - 一鍵執行
#===============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$SCRIPT_DIR/test_run_$(date +%Y%m%d_%H%M%S).log"

# 顏色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; }
log_section() { echo -e "\n${CYAN}========== $1 ==========${NC}\n" | tee -a "$LOG_FILE"; }

#-------------------------------------------------------------------------------
# 設定變數 - 請根據環境修改
#-------------------------------------------------------------------------------
# 測試用硬碟（至少需要 4 顆）
DISKS=("/dev/sdb" "/dev/sdc" "/dev/sdd" "/dev/sde")

# SLOG 裝置（可選，用於 sync write 測試）
SLOG_DEVICE=""  # 例如 "/dev/nvme0n1p1"

# 測試模式：quick（快速）或 full（完整）
TEST_MODE="${1:-quick}"

#-------------------------------------------------------------------------------
# 前置檢查
#-------------------------------------------------------------------------------
check_environment() {
    log_section "環境檢查"
    
    # Root 權限
    if [[ $EUID -ne 0 ]]; then
        log_error "請使用 root 權限執行"
        exit 1
    fi
    
    # 檢查硬碟
    log_info "檢查硬碟..."
    for disk in "${DISKS[@]}"; do
        if [[ ! -b "$disk" ]]; then
            log_error "硬碟不存在: $disk"
            log_warn "請修改腳本中的 DISKS 變數"
            exit 1
        fi
        log_info "  ✓ $disk"
    done
    
    # 安裝依賴
    log_info "安裝依賴套件..."
    apt update
    apt install -y mdadm zfsutils-linux fio iozone3 jq bc python3-pip
    pip3 install pandas matplotlib tabulate --break-system-packages 2>/dev/null || \
    pip3 install pandas matplotlib tabulate
    
    # 載入 ZFS 模組
    modprobe zfs || true
    
    log_info "環境檢查完成"
}

#-------------------------------------------------------------------------------
# 更新腳本中的硬碟設定
#-------------------------------------------------------------------------------
update_disk_config() {
    log_info "更新硬碟設定..."
    
    local disk_array="(\"${DISKS[0]}\" \"${DISKS[1]}\" \"${DISKS[2]}\" \"${DISKS[3]}\")"
    
    sed -i "s|^DISKS=.*|DISKS=$disk_array|" "$SCRIPT_DIR/01_setup_mdadm.sh"
    sed -i "s|^DISKS=.*|DISKS=$disk_array|" "$SCRIPT_DIR/02_setup_zfs.sh"
}

#-------------------------------------------------------------------------------
# 執行測試序列
#-------------------------------------------------------------------------------
run_mdadm_tests() {
    log_section "mdadm RAID 測試"
    
    local raid_types=("raid5" "raid6" "raid10")
    
    for raid in "${raid_types[@]}"; do
        log_info "設定 mdadm $raid..."
        bash "$SCRIPT_DIR/01_setup_mdadm.sh" "$raid"
        
        log_info "執行 throughput 測試..."
        bash "$SCRIPT_DIR/03_throughput_test.sh" mdadm
        
        if [[ "$TEST_MODE" == "full" ]]; then
            log_info "執行 latency 測試..."
            bash "$SCRIPT_DIR/04_latency_test.sh" mdadm
            
            log_info "執行 sync write 測試..."
            bash "$SCRIPT_DIR/05_sync_write_test.sh" mdadm
        fi
        
        log_info "清理 mdadm..."
        bash "$SCRIPT_DIR/01_setup_mdadm.sh" cleanup
    done
}

run_zfs_tests() {
    log_section "ZFS RAID 測試"
    
    local raid_types=("raidz1" "raidz2" "mirror")
    
    for raid in "${raid_types[@]}"; do
        log_info "設定 ZFS $raid..."
        bash "$SCRIPT_DIR/02_setup_zfs.sh" "$raid"
        
        log_info "執行 throughput 測試..."
        bash "$SCRIPT_DIR/03_throughput_test.sh" zfs
        
        if [[ "$TEST_MODE" == "full" ]]; then
            log_info "執行 latency 測試..."
            bash "$SCRIPT_DIR/04_latency_test.sh" zfs
            
            log_info "執行 sync write 測試..."
            bash "$SCRIPT_DIR/05_sync_write_test.sh" zfs
            
            log_info "執行 cache 測試..."
            bash "$SCRIPT_DIR/06_cache_test.sh" arc
            
            log_info "執行 compression 測試..."
            bash "$SCRIPT_DIR/07_compression_checksum_test.sh" all
        fi
        
        # SLOG 測試
        if [[ -n "$SLOG_DEVICE" ]] && [[ -b "$SLOG_DEVICE" ]]; then
            log_info "執行 SLOG 測試..."
            bash "$SCRIPT_DIR/05_sync_write_test.sh" slog "$raid" "$SLOG_DEVICE"
        fi
        
        log_info "清理 ZFS..."
        bash "$SCRIPT_DIR/02_setup_zfs.sh" cleanup
    done
}

#-------------------------------------------------------------------------------
# 分析結果
#-------------------------------------------------------------------------------
analyze_results() {
    log_section "結果分析"
    
    log_info "執行 Python 分析..."
    python3 "$SCRIPT_DIR/08_analyze_results.py"
    
    log_info "分析完成"
}

#-------------------------------------------------------------------------------
# 顯示使用說明
#-------------------------------------------------------------------------------
show_usage() {
    cat << EOF
用法: $0 [quick|full|mdadm|zfs|analyze]

模式:
  quick   - 快速測試（只測 throughput）
  full    - 完整測試（所有項目）
  mdadm   - 只測 mdadm
  zfs     - 只測 ZFS
  analyze - 只分析現有結果

環境設定:
  請修改腳本開頭的以下變數：
  - DISKS: 測試用硬碟（至少 4 顆）
  - SLOG_DEVICE: SLOG 裝置（可選）

範例:
  sudo $0 quick    # 快速測試
  sudo $0 full     # 完整測試
  sudo $0 analyze  # 分析結果
EOF
}

#-------------------------------------------------------------------------------
# 主程式
#-------------------------------------------------------------------------------
main() {
    echo "=============================================="
    echo "  mdadm vs ZFS 比較測試"
    echo "  模式: $TEST_MODE"
    echo "=============================================="
    
    case "$TEST_MODE" in
        quick|full)
            check_environment
            update_disk_config
            run_mdadm_tests
            run_zfs_tests
            analyze_results
            ;;
        mdadm)
            check_environment
            update_disk_config
            run_mdadm_tests
            analyze_results
            ;;
        zfs)
            check_environment
            update_disk_config
            run_zfs_tests
            analyze_results
            ;;
        analyze)
            analyze_results
            ;;
        help|--help|-h)
            show_usage
            exit 0
            ;;
        *)
            log_error "未知模式: $TEST_MODE"
            show_usage
            exit 1
            ;;
    esac
    
    log_section "測試完成"
    log_info "日誌檔案: $LOG_FILE"
    log_info "結果目錄: $SCRIPT_DIR/results/"
    log_info "分析報告: $SCRIPT_DIR/analysis/"
    
    echo ""
    echo "=============================================="
    echo "  測試完成！"
    echo "=============================================="
}

main
