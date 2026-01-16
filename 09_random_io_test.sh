#!/bin/bash
#===============================================================================
# 09_random_io_test.sh
# ランダムI/O評価 - fio ランダム読み書きテスト
# 測試項目：隨機讀寫效能（不同 block size、iodepth、混合比例）
# 包含 CPU/Memory 使用率監控
#===============================================================================

set -e

# 設定
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/results/random_io"
RESOURCE_DIR="${SCRIPT_DIR}/results/resources"
MONITOR_SCRIPT="${SCRIPT_DIR}/monitor_resources.sh"

# 建立目錄
mkdir -p "$RESULT_DIR"
mkdir -p "$RESOURCE_DIR"

# FIO 參數
FIO_RUNTIME=60        # 每個測試運行時間（秒）
FIO_RAMP=5            # 預熱時間
FILE_SIZE="4G"        # 測試檔案大小

# 測試參數
BLOCK_SIZES=("4k" "8k" "16k" "64k" "128k")
IODEPTH_LIST=(1 4 16 32 64)
RW_MIX_LIST=(100 70 50 30 0)  # 讀取比例：100=純讀、70=7讀3寫、50=混合、0=純寫

# 顏色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_test() { echo -e "${YELLOW}[TEST]${NC} $1"; }
log_section() { echo -e "\n${CYAN}========== $1 ==========${NC}\n"; }

# 啟動資源監控
start_resource_monitor() {
    local test_name="$1"
    if [[ -x "$MONITOR_SCRIPT" ]]; then
        log_info "啟動資源監控: $test_name"
        "$MONITOR_SCRIPT" start "random_${test_name}"
    else
        log_info "警告: 監控腳本不存在或無執行權限: $MONITOR_SCRIPT"
    fi
}

# 停止資源監控
stop_resource_monitor() {
    if [[ -x "$MONITOR_SCRIPT" ]]; then
        log_info "停止資源監控"
        "$MONITOR_SCRIPT" stop || true
    fi
}

#-------------------------------------------------------------------------------
# 隨機讀寫測試函數
#-------------------------------------------------------------------------------
run_random_test() {
    local test_name="$1"
    local test_dir="$2"
    local block_size="$3"
    local iodepth="$4"
    local rwmixread="$5"  # 讀取比例 (0-100)
    
    # 決定測試類型
    local rw_type
    if [[ "$rwmixread" -eq 100 ]]; then
        rw_type="randread"
    elif [[ "$rwmixread" -eq 0 ]]; then
        rw_type="randwrite"
    else
        rw_type="randrw"
    fi
    
    local output_file="$RESULT_DIR/${test_name}_${rw_type}_bs${block_size}_iod${iodepth}_mix${rwmixread}.json"
    
    log_test "$test_name - $rw_type - bs=$block_size iodepth=$iodepth rwmix=$rwmixread"
    
    # 清除快取
    sync
    echo 3 > /proc/sys/vm/drop_caches
    
    # 構建 FIO 命令
    local fio_cmd="fio --name=${test_name}_random \
        --directory=$test_dir \
        --ioengine=libaio \
        --direct=1 \
        --rw=$rw_type \
        --bs=$block_size \
        --size=$FILE_SIZE \
        --numjobs=1 \
        --iodepth=$iodepth \
        --runtime=$FIO_RUNTIME \
        --time_based \
        --ramp_time=$FIO_RAMP \
        --lat_percentiles=1 \
        --group_reporting \
        --output-format=json \
        --output=$output_file"
    
    # 如果是混合讀寫，加入 rwmixread 參數
    if [[ "$rw_type" == "randrw" ]]; then
        fio_cmd="$fio_cmd --rwmixread=$rwmixread"
    fi
    
    eval $fio_cmd
    
    # 提取結果
    local read_iops=0 write_iops=0 read_bw=0 write_bw=0
    local read_lat_p50=0 read_lat_p99=0 read_lat_p999=0 read_lat_p9999=0
    local write_lat_p50=0 write_lat_p99=0 write_lat_p999=0 write_lat_p9999=0
    
    if [[ "$rwmixread" -gt 0 ]]; then
        read_iops=$(jq -r '.jobs[0].read.iops // 0' "$output_file")
        read_bw=$(jq -r '.jobs[0].read.bw_bytes // 0' "$output_file")
        read_lat_p50=$(jq -r '.jobs[0].read.clat_ns.percentile["50.000000"] // 0' "$output_file")
        read_lat_p99=$(jq -r '.jobs[0].read.clat_ns.percentile["99.000000"] // 0' "$output_file")
        read_lat_p999=$(jq -r '.jobs[0].read.clat_ns.percentile["99.900000"] // 0' "$output_file")
        read_lat_p9999=$(jq -r '.jobs[0].read.clat_ns.percentile["99.990000"] // 0' "$output_file")
    fi
    
    if [[ "$rwmixread" -lt 100 ]]; then
        write_iops=$(jq -r '.jobs[0].write.iops // 0' "$output_file")
        write_bw=$(jq -r '.jobs[0].write.bw_bytes // 0' "$output_file")
        write_lat_p50=$(jq -r '.jobs[0].write.clat_ns.percentile["50.000000"] // 0' "$output_file")
        write_lat_p99=$(jq -r '.jobs[0].write.clat_ns.percentile["99.000000"] // 0' "$output_file")
        write_lat_p999=$(jq -r '.jobs[0].write.clat_ns.percentile["99.900000"] // 0' "$output_file")
        write_lat_p9999=$(jq -r '.jobs[0].write.clat_ns.percentile["99.990000"] // 0' "$output_file")
    fi
    
    # 轉換單位
    local read_bw_mb=$(echo "scale=2; $read_bw / 1024 / 1024" | bc)
    local write_bw_mb=$(echo "scale=2; $write_bw / 1024 / 1024" | bc)
    local read_lat_p99_us=$(echo "scale=2; $read_lat_p99 / 1000" | bc)
    local write_lat_p99_us=$(echo "scale=2; $write_lat_p99 / 1000" | bc)
    
    echo "  Read:  IOPS=${read_iops}, BW=${read_bw_mb}MB/s, P99=${read_lat_p99_us}us"
    echo "  Write: IOPS=${write_iops}, BW=${write_bw_mb}MB/s, P99=${write_lat_p99_us}us"
    
    # 清理測試檔案
    rm -f "$test_dir"/*.0.*
}

#-------------------------------------------------------------------------------
# mdadm 隨機測試
#-------------------------------------------------------------------------------
test_mdadm_random() {
    local raid_type="$1"
    local test_dir="/mnt/mdadm_test/$raid_type"
    
    if [[ ! -d "$test_dir" ]]; then
        log_info "目錄不存在: $test_dir，跳過"
        return
    fi
    
    log_section "mdadm $raid_type ランダムI/Oテスト"
    
    # 啟動資源監控
    start_resource_monitor "mdadm_${raid_type}"
    
    # Block Size 測試（固定 iodepth=32, 純讀/純寫）
    log_info "--- Block Size 比較 ---"
    for bs in "${BLOCK_SIZES[@]}"; do
        run_random_test "mdadm_${raid_type}" "$test_dir" "$bs" 32 100  # 純讀
        run_random_test "mdadm_${raid_type}" "$test_dir" "$bs" 32 0    # 純寫
    done
    
    # IODepth 測試（固定 bs=4k）
    log_info "--- IODepth 比較 ---"
    for iod in "${IODEPTH_LIST[@]}"; do
        run_random_test "mdadm_${raid_type}" "$test_dir" "4k" "$iod" 100  # 純讀
        run_random_test "mdadm_${raid_type}" "$test_dir" "4k" "$iod" 0    # 純寫
    done
    
    # 混合讀寫比例測試（固定 bs=4k, iodepth=32）
    log_info "--- 読み書き混合比率 比較 ---"
    for mix in "${RW_MIX_LIST[@]}"; do
        run_random_test "mdadm_${raid_type}" "$test_dir" "4k" 32 "$mix"
    done
    
    # 停止資源監控
    stop_resource_monitor
}

#-------------------------------------------------------------------------------
# ZFS 隨機測試
#-------------------------------------------------------------------------------
test_zfs_random() {
    local raid_type="$1"
    local test_dir="/mnt/zfs_test/$raid_type"
    
    if [[ ! -d "$test_dir" ]]; then
        log_info "目錄不存在: $test_dir，跳過"
        return
    fi
    
    log_section "ZFS $raid_type ランダムI/Oテスト"
    
    # 啟動資源監控
    start_resource_monitor "zfs_${raid_type}"
    
    # Block Size 測試
    log_info "--- Block Size 比較 ---"
    for bs in "${BLOCK_SIZES[@]}"; do
        run_random_test "zfs_${raid_type}" "$test_dir" "$bs" 32 100
        run_random_test "zfs_${raid_type}" "$test_dir" "$bs" 32 0
    done
    
    # IODepth 測試
    log_info "--- IODepth 比較 ---"
    for iod in "${IODEPTH_LIST[@]}"; do
        run_random_test "zfs_${raid_type}" "$test_dir" "4k" "$iod" 100
        run_random_test "zfs_${raid_type}" "$test_dir" "4k" "$iod" 0
    done
    
    # 混合讀寫比例測試
    log_info "--- 読み書き混合比率 比較 ---"
    for mix in "${RW_MIX_LIST[@]}"; do
        run_random_test "zfs_${raid_type}" "$test_dir" "4k" 32 "$mix"
    done
    
    # 停止資源監控
    stop_resource_monitor
}

#-------------------------------------------------------------------------------
# ZFS recordsize 對隨機 I/O 的影響
#-------------------------------------------------------------------------------
test_zfs_recordsize_random() {
    local pool_type="$1"
    local pool_name="testpool_${pool_type}"
    local base_dir="/mnt/zfs_test/$pool_type"
    
    if ! zpool list "$pool_name" &>/dev/null; then
        log_info "Pool 不存在: $pool_name，跳過"
        return
    fi
    
    log_section "ZFS $pool_type recordsize vs ランダムI/O"
    
    local recordsizes=("4K" "8K" "16K" "128K")
    
    for rs in "${recordsizes[@]}"; do
        local dataset="${pool_name}/random_rs${rs}"
        local test_dir="${base_dir}/random_rs${rs}"
        
        log_info "測試 recordsize=$rs"
        
        # 建立 dataset
        zfs destroy "$dataset" 2>/dev/null || true
        zfs create -o recordsize="$rs" "$dataset"
        
        # 測試 4K 隨機讀寫
        run_random_test "zfs_${pool_type}_rs${rs}" "$test_dir" "4k" 32 100
        run_random_test "zfs_${pool_type}_rs${rs}" "$test_dir" "4k" 32 0
        
        # 清理
        zfs destroy "$dataset"
    done
}

#-------------------------------------------------------------------------------
# 生成摘要報告
#-------------------------------------------------------------------------------
generate_summary() {
    local summary_file="$RESULT_DIR/random_io_summary.csv"
    
    log_info "生成隨機 I/O 摘要報告..."
    
    echo "test_name,rw_type,block_size,iodepth,rwmix,read_iops,write_iops,read_bw_MBps,write_bw_MBps,read_p50_us,read_p99_us,read_p999_us,read_p9999_us,write_p50_us,write_p99_us,write_p999_us,write_p9999_us" > "$summary_file"
    
    for json_file in "$RESULT_DIR"/*.json; do
        [[ -f "$json_file" ]] || continue
        
        local filename=$(basename "$json_file" .json)
        
        # 解析檔名: test_name_rwtype_bsXX_iodXX_mixXX
        if [[ "$filename" =~ (.+)_(randread|randwrite|randrw)_bs([0-9]+k?)_iod([0-9]+)_mix([0-9]+) ]]; then
            local test_name="${BASH_REMATCH[1]}"
            local rw_type="${BASH_REMATCH[2]}"
            local block_size="${BASH_REMATCH[3]}"
            local iodepth="${BASH_REMATCH[4]}"
            local rwmix="${BASH_REMATCH[5]}"
            
            # 讀取數據
            local read_iops=$(jq -r '.jobs[0].read.iops // 0' "$json_file")
            local write_iops=$(jq -r '.jobs[0].write.iops // 0' "$json_file")
            local read_bw=$(jq -r '.jobs[0].read.bw_bytes // 0' "$json_file")
            local write_bw=$(jq -r '.jobs[0].write.bw_bytes // 0' "$json_file")
            
            local read_p50=$(jq -r '.jobs[0].read.clat_ns.percentile["50.000000"] // 0' "$json_file")
            local read_p99=$(jq -r '.jobs[0].read.clat_ns.percentile["99.000000"] // 0' "$json_file")
            local read_p999=$(jq -r '.jobs[0].read.clat_ns.percentile["99.900000"] // 0' "$json_file")
            local read_p9999=$(jq -r '.jobs[0].read.clat_ns.percentile["99.990000"] // 0' "$json_file")
            
            local write_p50=$(jq -r '.jobs[0].write.clat_ns.percentile["50.000000"] // 0' "$json_file")
            local write_p99=$(jq -r '.jobs[0].write.clat_ns.percentile["99.000000"] // 0' "$json_file")
            local write_p999=$(jq -r '.jobs[0].write.clat_ns.percentile["99.900000"] // 0' "$json_file")
            local write_p9999=$(jq -r '.jobs[0].write.clat_ns.percentile["99.990000"] // 0' "$json_file")
            
            # 轉換單位
            local read_bw_mb=$(echo "scale=2; $read_bw / 1024 / 1024" | bc)
            local write_bw_mb=$(echo "scale=2; $write_bw / 1024 / 1024" | bc)
            local read_p50_us=$(echo "scale=2; $read_p50 / 1000" | bc)
            local read_p99_us=$(echo "scale=2; $read_p99 / 1000" | bc)
            local read_p999_us=$(echo "scale=2; $read_p999 / 1000" | bc)
            local read_p9999_us=$(echo "scale=2; $read_p9999 / 1000" | bc)
            local write_p50_us=$(echo "scale=2; $write_p50 / 1000" | bc)
            local write_p99_us=$(echo "scale=2; $write_p99 / 1000" | bc)
            local write_p999_us=$(echo "scale=2; $write_p999 / 1000" | bc)
            local write_p9999_us=$(echo "scale=2; $write_p9999 / 1000" | bc)
            
            echo "$test_name,$rw_type,$block_size,$iodepth,$rwmix,$read_iops,$write_iops,$read_bw_mb,$write_bw_mb,$read_p50_us,$read_p99_us,$read_p999_us,$read_p9999_us,$write_p50_us,$write_p99_us,$write_p999_us,$write_p9999_us" >> "$summary_file"
        fi
    done
    
    log_info "摘要已儲存: $summary_file"
    
    echo ""
    echo "=============================================="
    echo "ランダムI/O測試結果摘要"
    echo "=============================================="
    column -t -s',' "$summary_file" | head -40
}

#-------------------------------------------------------------------------------
# 主程式
#-------------------------------------------------------------------------------
main() {
    local target="${1:-all}"
    
    log_info "開始ランダムI/O評価測試"
    log_info "結果目錄: $RESULT_DIR"
    
    # 檢查依賴
    if ! command -v fio &> /dev/null; then
        apt update && apt install -y fio jq bc
    fi
    
    case "$target" in
        mdadm)
            test_mdadm_random "raid5"
            test_mdadm_random "raid6"
            test_mdadm_random "raid10"
            ;;
        zfs)
            test_zfs_random "raidz1"
            test_zfs_random "raidz2"
            test_zfs_random "mirror"
            ;;
        recordsize)
            test_zfs_recordsize_random "raidz1"
            ;;
        all)
            # mdadm 測試
            test_mdadm_random "raid5"
            test_mdadm_random "raid6"
            test_mdadm_random "raid10"
            
            # ZFS 測試
            test_zfs_random "raidz1"
            test_zfs_random "raidz2"
            test_zfs_random "mirror"
            
            # recordsize 測試
            test_zfs_recordsize_random "raidz1"
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
