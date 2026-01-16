#!/bin/bash
#===============================================================================
# 04_latency_test.sh
# レイテンシ評価 - fio ランダム 4KB 読み書き p99/p999 測定
# 包含 CPU/Memory 使用率監控
#===============================================================================

set -e

# 設定
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/results/latency"
MONITOR_SCRIPT="${SCRIPT_DIR}/monitor_resources.sh"

# 啟動資源監控
start_resource_monitor() {
    local test_name="$1"
    if [[ -x "$MONITOR_SCRIPT" ]]; then
        "$MONITOR_SCRIPT" start "latency_${test_name}" &>/dev/null
    fi
}

# 停止資源監控
stop_resource_monitor() {
    if [[ -x "$MONITOR_SCRIPT" ]]; then
        "$MONITOR_SCRIPT" stop &>/dev/null || true
    fi
}
FIO_RUNTIME=120       # 延遲測試需要較長時間取得準確數據
FIO_RAMP=10
BLOCK_SIZE="4k"
FILE_SIZE="4G"
IODEPTH_LIST=(1 4 16 32)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_test() { echo -e "${YELLOW}[TEST]${NC} $1"; }

mkdir -p "$RESULT_DIR"

#-------------------------------------------------------------------------------
# 延遲測試函數
#-------------------------------------------------------------------------------
run_latency_test() {
    local test_name="$1"
    local test_dir="$2"
    local rw_type="$3"  # randread, randwrite, randrw
    local iodepth="$4"
    
    local output_file="$RESULT_DIR/${test_name}_${rw_type}_iod${iodepth}.json"
    
    log_test "$test_name - $rw_type - iodepth=$iodepth"
    
    # 清除快取
    sync
    echo 3 > /proc/sys/vm/drop_caches
    
    fio --name="${test_name}_latency" \
        --directory="$test_dir" \
        --ioengine=libaio \
        --direct=1 \
        --rw="$rw_type" \
        --bs="$BLOCK_SIZE" \
        --size="$FILE_SIZE" \
        --numjobs=1 \
        --iodepth="$iodepth" \
        --runtime=$FIO_RUNTIME \
        --time_based \
        --ramp_time=$FIO_RAMP \
        --lat_percentiles=1 \
        --group_reporting \
        --output-format=json \
        --output="$output_file"
    
    # 提取延遲數據
    if [[ "$rw_type" == "randwrite" ]]; then
        local lat_mean=$(jq -r '.jobs[0].write.lat_ns.mean // 0' "$output_file")
        local lat_p99=$(jq -r '.jobs[0].write.clat_ns.percentile["99.000000"] // 0' "$output_file")
        local lat_p999=$(jq -r '.jobs[0].write.clat_ns.percentile["99.900000"] // 0' "$output_file")
        local iops=$(jq -r '.jobs[0].write.iops // 0' "$output_file")
    elif [[ "$rw_type" == "randread" ]]; then
        local lat_mean=$(jq -r '.jobs[0].read.lat_ns.mean // 0' "$output_file")
        local lat_p99=$(jq -r '.jobs[0].read.clat_ns.percentile["99.000000"] // 0' "$output_file")
        local lat_p999=$(jq -r '.jobs[0].read.clat_ns.percentile["99.900000"] // 0' "$output_file")
        local iops=$(jq -r '.jobs[0].read.iops // 0' "$output_file")
    else
        # randrw - 取讀取的數據
        local lat_mean=$(jq -r '.jobs[0].read.lat_ns.mean // 0' "$output_file")
        local lat_p99=$(jq -r '.jobs[0].read.clat_ns.percentile["99.000000"] // 0' "$output_file")
        local lat_p999=$(jq -r '.jobs[0].read.clat_ns.percentile["99.900000"] // 0' "$output_file")
        local iops=$(jq -r '(.jobs[0].read.iops // 0) + (.jobs[0].write.iops // 0)' "$output_file")
    fi
    
    # 轉換為 microseconds
    local lat_mean_us=$(echo "scale=2; $lat_mean / 1000" | bc)
    local lat_p99_us=$(echo "scale=2; $lat_p99 / 1000" | bc)
    local lat_p999_us=$(echo "scale=2; $lat_p999 / 1000" | bc)
    
    echo "  Mean: ${lat_mean_us}us, P99: ${lat_p99_us}us, P99.9: ${lat_p999_us}us, IOPS: ${iops}"
    
    # 清理
    rm -f "$test_dir"/*.0.*
}

#-------------------------------------------------------------------------------
# mdadm 延遲測試
#-------------------------------------------------------------------------------
test_mdadm_latency() {
    local raid_type="$1"
    local test_dir="/mnt/mdadm_test/$raid_type"
    
    if [[ ! -d "$test_dir" ]]; then
        log_info "目錄不存在: $test_dir，跳過"
        return
    fi
    
    log_info "===== mdadm $raid_type レイテンシテスト ====="
    
    # 啟動資源監控
    start_resource_monitor "mdadm_${raid_type}"
    
    for iodepth in "${IODEPTH_LIST[@]}"; do
        run_latency_test "mdadm_${raid_type}" "$test_dir" "randread" "$iodepth"
        run_latency_test "mdadm_${raid_type}" "$test_dir" "randwrite" "$iodepth"
        run_latency_test "mdadm_${raid_type}" "$test_dir" "randrw" "$iodepth"
    done
    
    # 停止資源監控
    stop_resource_monitor
}

#-------------------------------------------------------------------------------
# ZFS 延遲測試
#-------------------------------------------------------------------------------
test_zfs_latency() {
    local raid_type="$1"
    local test_dir="/mnt/zfs_test/$raid_type"
    
    if [[ ! -d "$test_dir" ]]; then
        log_info "目錄不存在: $test_dir，跳過"
        return
    fi
    
    log_info "===== ZFS $raid_type レイテンシテスト ====="
    
    # 啟動資源監控
    start_resource_monitor "zfs_${raid_type}"
    
    for iodepth in "${IODEPTH_LIST[@]}"; do
        run_latency_test "zfs_${raid_type}" "$test_dir" "randread" "$iodepth"
        run_latency_test "zfs_${raid_type}" "$test_dir" "randwrite" "$iodepth"
        run_latency_test "zfs_${raid_type}" "$test_dir" "randrw" "$iodepth"
    done
    
    # 停止資源監控
    stop_resource_monitor
}

#-------------------------------------------------------------------------------
# ZFS recordsize 對延遲的影響
#-------------------------------------------------------------------------------
test_zfs_recordsize_latency() {
    local pool_type="$1"
    local recordsizes=("rs4k" "rs128k")
    
    log_info "===== ZFS $pool_type recordsize vs レイテンシ ====="
    
    for rs in "${recordsizes[@]}"; do
        local test_dir="/mnt/zfs_test/${pool_type}/${rs}"
        
        if [[ ! -d "$test_dir" ]]; then
            continue
        fi
        
        log_info "Testing recordsize: $rs"
        
        # 只測試 iodepth=1 和 16
        for iodepth in 1 16; do
            run_latency_test "zfs_${pool_type}_${rs}" "$test_dir" "randread" "$iodepth"
            run_latency_test "zfs_${pool_type}_${rs}" "$test_dir" "randwrite" "$iodepth"
        done
    done
}

#-------------------------------------------------------------------------------
# 生成摘要
#-------------------------------------------------------------------------------
generate_summary() {
    local summary_file="$RESULT_DIR/latency_summary.csv"
    
    log_info "生成延遲摘要報告..."
    
    echo "test_name,rw_type,iodepth,lat_mean_us,lat_p99_us,lat_p999_us,iops" > "$summary_file"
    
    for json_file in "$RESULT_DIR"/*.json; do
        [[ -f "$json_file" ]] || continue
        
        local filename=$(basename "$json_file" .json)
        
        if [[ "$filename" =~ (.+)_(randread|randwrite|randrw)_iod([0-9]+) ]]; then
            local test_name="${BASH_REMATCH[1]}"
            local rw_type="${BASH_REMATCH[2]}"
            local iodepth="${BASH_REMATCH[3]}"
            
            if [[ "$rw_type" == "randwrite" ]]; then
                local lat_mean=$(jq -r '.jobs[0].write.lat_ns.mean // 0' "$json_file")
                local lat_p99=$(jq -r '.jobs[0].write.clat_ns.percentile["99.000000"] // 0' "$json_file")
                local lat_p999=$(jq -r '.jobs[0].write.clat_ns.percentile["99.900000"] // 0' "$json_file")
                local iops=$(jq -r '.jobs[0].write.iops // 0' "$json_file")
            elif [[ "$rw_type" == "randread" ]]; then
                local lat_mean=$(jq -r '.jobs[0].read.lat_ns.mean // 0' "$json_file")
                local lat_p99=$(jq -r '.jobs[0].read.clat_ns.percentile["99.000000"] // 0' "$json_file")
                local lat_p999=$(jq -r '.jobs[0].read.clat_ns.percentile["99.900000"] // 0' "$json_file")
                local iops=$(jq -r '.jobs[0].read.iops // 0' "$json_file")
            else
                local lat_mean=$(jq -r '.jobs[0].read.lat_ns.mean // 0' "$json_file")
                local lat_p99=$(jq -r '.jobs[0].read.clat_ns.percentile["99.000000"] // 0' "$json_file")
                local lat_p999=$(jq -r '.jobs[0].read.clat_ns.percentile["99.900000"] // 0' "$json_file")
                local iops=$(jq -r '(.jobs[0].read.iops // 0) + (.jobs[0].write.iops // 0)' "$json_file")
            fi
            
            local lat_mean_us=$(echo "scale=2; $lat_mean / 1000" | bc)
            local lat_p99_us=$(echo "scale=2; $lat_p99 / 1000" | bc)
            local lat_p999_us=$(echo "scale=2; $lat_p999 / 1000" | bc)
            
            echo "$test_name,$rw_type,$iodepth,$lat_mean_us,$lat_p99_us,$lat_p999_us,$iops" >> "$summary_file"
        fi
    done
    
    log_info "摘要已儲存: $summary_file"
    
    echo ""
    echo "=============================================="
    echo "レイテンシ測試結果摘要"
    echo "=============================================="
    column -t -s',' "$summary_file" | head -30
}

#-------------------------------------------------------------------------------
# 主程式
#-------------------------------------------------------------------------------
main() {
    local target="${1:-all}"
    
    log_info "開始レイテンシ評価測試"
    log_info "結果目錄: $RESULT_DIR"
    
    if ! command -v fio &> /dev/null; then
        apt update && apt install -y fio jq bc
    fi
    
    case "$target" in
        mdadm)
            test_mdadm_latency "raid5"
            test_mdadm_latency "raid6"
            test_mdadm_latency "raid10"
            ;;
        zfs)
            test_zfs_latency "raidz1"
            test_zfs_latency "raidz2"
            test_zfs_latency "mirror"
            ;;
        recordsize)
            test_zfs_recordsize_latency "raidz1"
            ;;
        all)
            test_mdadm_latency "raid5"
            test_mdadm_latency "raid6"
            test_mdadm_latency "raid10"
            test_zfs_latency "raidz1"
            test_zfs_latency "raidz2"
            test_zfs_latency "mirror"
            test_zfs_recordsize_latency "raidz1"
            ;;
        summary)
            ;;
        *)
            echo "用法: $0 {mdadm|zfs|recordsize|all|summary}"
            exit 1
            ;;
    esac
    
    generate_summary
}

main "$@"
