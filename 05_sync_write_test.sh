#!/bin/bash
#===============================================================================
# 05_sync_write_test.sh
# 同期書き込み評価 - sync=always vs sync=disabled, SLOG 効果測定
#===============================================================================

set -e

# 設定
RESULT_DIR="/home/claude/mdadm_zfs_benchmark/results/sync_write"
FIO_RUNTIME=60
FIO_RAMP=5
BLOCK_SIZE="4k"
FILE_SIZE="1G"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_test() { echo -e "${YELLOW}[TEST]${NC} $1"; }
log_note() { echo -e "${CYAN}[NOTE]${NC} $1"; }

mkdir -p "$RESULT_DIR"

#-------------------------------------------------------------------------------
# mdadm sync write 測試
#-------------------------------------------------------------------------------
test_mdadm_sync() {
    local raid_type="$1"
    local test_dir="/mnt/mdadm_test/$raid_type"
    
    if [[ ! -d "$test_dir" ]]; then
        log_info "目錄不存在: $test_dir，跳過"
        return
    fi
    
    log_info "===== mdadm $raid_type 同期書き込みテスト ====="
    
    # 非同步寫入 (fsync=0)
    log_test "mdadm $raid_type - async write (fsync=0)"
    sync; echo 3 > /proc/sys/vm/drop_caches
    
    fio --name="mdadm_${raid_type}_async" \
        --directory="$test_dir" \
        --ioengine=libaio \
        --direct=1 \
        --rw=write \
        --bs="$BLOCK_SIZE" \
        --size="$FILE_SIZE" \
        --numjobs=1 \
        --iodepth=32 \
        --fsync=0 \
        --runtime=$FIO_RUNTIME \
        --time_based \
        --group_reporting \
        --output-format=json \
        --output="$RESULT_DIR/mdadm_${raid_type}_async.json"
    
    local bw=$(jq -r '.jobs[0].write.bw_bytes' "$RESULT_DIR/mdadm_${raid_type}_async.json")
    local bw_mb=$(echo "scale=2; $bw / 1024 / 1024" | bc)
    echo "  Async Bandwidth: ${bw_mb} MB/s"
    
    # 同步寫入 (fsync=1)
    log_test "mdadm $raid_type - sync write (fsync=1)"
    sync; echo 3 > /proc/sys/vm/drop_caches
    
    fio --name="mdadm_${raid_type}_sync" \
        --directory="$test_dir" \
        --ioengine=libaio \
        --direct=1 \
        --rw=write \
        --bs="$BLOCK_SIZE" \
        --size="$FILE_SIZE" \
        --numjobs=1 \
        --iodepth=1 \
        --fsync=1 \
        --runtime=$FIO_RUNTIME \
        --time_based \
        --group_reporting \
        --output-format=json \
        --output="$RESULT_DIR/mdadm_${raid_type}_sync.json"
    
    bw=$(jq -r '.jobs[0].write.bw_bytes' "$RESULT_DIR/mdadm_${raid_type}_sync.json")
    bw_mb=$(echo "scale=2; $bw / 1024 / 1024" | bc)
    echo "  Sync Bandwidth: ${bw_mb} MB/s"
    
    rm -f "$test_dir"/*.0.*
}

#-------------------------------------------------------------------------------
# ZFS sync 測試 (sync=disabled vs sync=always)
#-------------------------------------------------------------------------------
test_zfs_sync() {
    local pool_type="$1"
    local pool_name="testpool_${pool_type}"
    local test_dir="/mnt/zfs_test/$pool_type"
    
    if [[ ! -d "$test_dir" ]]; then
        log_info "目錄不存在: $test_dir，跳過"
        return
    fi
    
    log_info "===== ZFS $pool_type 同期書き込みテスト ====="
    
    # 建立測試用 dataset
    zfs create -o sync=disabled "${pool_name}/sync_test_async" 2>/dev/null || true
    zfs create -o sync=always "${pool_name}/sync_test_sync" 2>/dev/null || true
    
    # sync=disabled 測試
    log_test "ZFS $pool_type - sync=disabled"
    local async_dir="${test_dir}/sync_test_async"
    
    if [[ -d "$async_dir" ]]; then
        sync; echo 3 > /proc/sys/vm/drop_caches
        
        fio --name="zfs_${pool_type}_async" \
            --directory="$async_dir" \
            --ioengine=libaio \
            --direct=1 \
            --rw=write \
            --bs="$BLOCK_SIZE" \
            --size="$FILE_SIZE" \
            --numjobs=1 \
            --iodepth=32 \
            --runtime=$FIO_RUNTIME \
            --time_based \
            --group_reporting \
            --output-format=json \
            --output="$RESULT_DIR/zfs_${pool_type}_async.json"
        
        local bw=$(jq -r '.jobs[0].write.bw_bytes' "$RESULT_DIR/zfs_${pool_type}_async.json")
        local bw_mb=$(echo "scale=2; $bw / 1024 / 1024" | bc)
        echo "  sync=disabled Bandwidth: ${bw_mb} MB/s"
        
        rm -f "$async_dir"/*.0.*
    fi
    
    # sync=always 測試
    log_test "ZFS $pool_type - sync=always"
    local sync_dir="${test_dir}/sync_test_sync"
    
    if [[ -d "$sync_dir" ]]; then
        sync; echo 3 > /proc/sys/vm/drop_caches
        
        fio --name="zfs_${pool_type}_sync" \
            --directory="$sync_dir" \
            --ioengine=libaio \
            --direct=1 \
            --rw=write \
            --bs="$BLOCK_SIZE" \
            --size="$FILE_SIZE" \
            --numjobs=1 \
            --iodepth=1 \
            --runtime=$FIO_RUNTIME \
            --time_based \
            --group_reporting \
            --output-format=json \
            --output="$RESULT_DIR/zfs_${pool_type}_sync.json"
        
        bw=$(jq -r '.jobs[0].write.bw_bytes' "$RESULT_DIR/zfs_${pool_type}_sync.json")
        bw_mb=$(echo "scale=2; $bw / 1024 / 1024" | bc)
        echo "  sync=always Bandwidth: ${bw_mb} MB/s"
        
        rm -f "$sync_dir"/*.0.*
    fi
    
    # 清理測試 dataset
    zfs destroy "${pool_name}/sync_test_async" 2>/dev/null || true
    zfs destroy "${pool_name}/sync_test_sync" 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# ZFS SLOG 效果測試
#-------------------------------------------------------------------------------
test_zfs_slog() {
    local pool_type="$1"
    local pool_name="testpool_${pool_type}"
    local slog_device="$2"  # SLOG 裝置路徑
    
    if [[ -z "$slog_device" ]]; then
        log_note "未指定 SLOG 裝置，跳過 SLOG 測試"
        log_note "用法: $0 slog <pool_type> <slog_device>"
        return
    fi
    
    if [[ ! -b "$slog_device" ]]; then
        log_info "SLOG 裝置不存在: $slog_device"
        return
    fi
    
    log_info "===== ZFS $pool_type SLOG 効果測定 ====="
    
    local test_dir="/mnt/zfs_test/$pool_type"
    
    # 建立 sync=always dataset
    zfs create -o sync=always "${pool_name}/slog_test" 2>/dev/null || true
    local slog_test_dir="${test_dir}/slog_test"
    
    # 無 SLOG 測試
    log_test "Without SLOG"
    sync; echo 3 > /proc/sys/vm/drop_caches
    
    fio --name="zfs_${pool_type}_no_slog" \
        --directory="$slog_test_dir" \
        --ioengine=libaio \
        --direct=1 \
        --rw=write \
        --bs="$BLOCK_SIZE" \
        --size="$FILE_SIZE" \
        --numjobs=1 \
        --iodepth=1 \
        --runtime=$FIO_RUNTIME \
        --time_based \
        --group_reporting \
        --output-format=json \
        --output="$RESULT_DIR/zfs_${pool_type}_no_slog.json"
    
    local bw=$(jq -r '.jobs[0].write.bw_bytes' "$RESULT_DIR/zfs_${pool_type}_no_slog.json")
    local bw_mb=$(echo "scale=2; $bw / 1024 / 1024" | bc)
    echo "  Without SLOG: ${bw_mb} MB/s"
    
    rm -f "$slog_test_dir"/*.0.*
    
    # 新增 SLOG
    log_test "Adding SLOG: $slog_device"
    zpool add "$pool_name" log "$slog_device"
    
    # 有 SLOG 測試
    log_test "With SLOG"
    sync; echo 3 > /proc/sys/vm/drop_caches
    
    fio --name="zfs_${pool_type}_with_slog" \
        --directory="$slog_test_dir" \
        --ioengine=libaio \
        --direct=1 \
        --rw=write \
        --bs="$BLOCK_SIZE" \
        --size="$FILE_SIZE" \
        --numjobs=1 \
        --iodepth=1 \
        --runtime=$FIO_RUNTIME \
        --time_based \
        --group_reporting \
        --output-format=json \
        --output="$RESULT_DIR/zfs_${pool_type}_with_slog.json"
    
    bw=$(jq -r '.jobs[0].write.bw_bytes' "$RESULT_DIR/zfs_${pool_type}_with_slog.json")
    bw_mb=$(echo "scale=2; $bw / 1024 / 1024" | bc)
    echo "  With SLOG: ${bw_mb} MB/s"
    
    # 移除 SLOG
    log_test "Removing SLOG"
    zpool remove "$pool_name" "$slog_device"
    
    # 清理
    zfs destroy "${pool_name}/slog_test" 2>/dev/null || true
    rm -f "$slog_test_dir"/*.0.*
}

#-------------------------------------------------------------------------------
# 生成摘要
#-------------------------------------------------------------------------------
generate_summary() {
    local summary_file="$RESULT_DIR/sync_write_summary.csv"
    
    log_info "生成同步寫入摘要報告..."
    
    echo "test_name,sync_mode,bandwidth_MBps,iops,lat_mean_us" > "$summary_file"
    
    for json_file in "$RESULT_DIR"/*.json; do
        [[ -f "$json_file" ]] || continue
        
        local filename=$(basename "$json_file" .json)
        local bw=$(jq -r '.jobs[0].write.bw_bytes // 0' "$json_file")
        local iops=$(jq -r '.jobs[0].write.iops // 0' "$json_file")
        local lat=$(jq -r '.jobs[0].write.lat_ns.mean // 0' "$json_file")
        
        local bw_mb=$(echo "scale=2; $bw / 1024 / 1024" | bc)
        local lat_us=$(echo "scale=2; $lat / 1000" | bc)
        
        # 判斷 sync 模式
        local sync_mode="unknown"
        if [[ "$filename" =~ _async ]]; then
            sync_mode="async"
        elif [[ "$filename" =~ _sync ]]; then
            sync_mode="sync"
        elif [[ "$filename" =~ _no_slog ]]; then
            sync_mode="sync_no_slog"
        elif [[ "$filename" =~ _with_slog ]]; then
            sync_mode="sync_with_slog"
        fi
        
        echo "$filename,$sync_mode,$bw_mb,$iops,$lat_us" >> "$summary_file"
    done
    
    log_info "摘要已儲存: $summary_file"
    
    echo ""
    echo "=============================================="
    echo "同期書き込み測試結果摘要"
    echo "=============================================="
    column -t -s',' "$summary_file"
    
    echo ""
    log_note "SLOG 測試說明:"
    echo "  - SLOG (Separate Log) 是 ZFS 的寫入日誌快取裝置"
    echo "  - 使用 NVMe/SSD 作為 SLOG 可大幅提升 sync write 效能"
    echo "  - 對 async write 無影響"
}

#-------------------------------------------------------------------------------
# 主程式
#-------------------------------------------------------------------------------
main() {
    local target="${1:-all}"
    
    log_info "開始同期書き込み評価測試"
    log_info "結果目錄: $RESULT_DIR"
    
    if ! command -v fio &> /dev/null; then
        apt update && apt install -y fio jq bc
    fi
    
    case "$target" in
        mdadm)
            test_mdadm_sync "raid5"
            test_mdadm_sync "raid6"
            test_mdadm_sync "raid10"
            ;;
        zfs)
            test_zfs_sync "raidz1"
            test_zfs_sync "raidz2"
            test_zfs_sync "mirror"
            ;;
        slog)
            # 用法: ./05_sync_write_test.sh slog raidz1 /dev/nvme0n1
            test_zfs_slog "${2:-raidz1}" "${3:-}"
            ;;
        all)
            test_mdadm_sync "raid5"
            test_mdadm_sync "raid6"
            test_mdadm_sync "raid10"
            test_zfs_sync "raidz1"
            test_zfs_sync "raidz2"
            test_zfs_sync "mirror"
            ;;
        summary)
            ;;
        *)
            echo "用法: $0 {mdadm|zfs|slog|all|summary}"
            echo "  slog: $0 slog <pool_type> <slog_device>"
            exit 1
            ;;
    esac
    
    generate_summary
}

main "$@"
