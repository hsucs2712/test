#!/bin/bash
#===============================================================================
# 03_throughput_test.sh
# スループット評価 - fio シーケンシャル読み書きテスト
# 測試項目：1GB～10GB 檔案的循序讀寫效能
#===============================================================================

set -e

# 設定
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/results/throughput"
FIO_RUNTIME=60        # 每個測試運行時間（秒）
FIO_RAMP=5            # 預熱時間
FILE_SIZES=("1G" "5G" "10G")
BLOCK_SIZES=("128k" "1m")
NUMJOBS=1
IODEPTH=32

# 顏色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_test() { echo -e "${YELLOW}[TEST]${NC} $1"; }

mkdir -p "$RESULT_DIR"

#-------------------------------------------------------------------------------
# 通用 FIO 測試函數
#-------------------------------------------------------------------------------
run_fio_throughput() {
    local test_name="$1"
    local test_dir="$2"
    local file_size="$3"
    local block_size="$4"
    local rw_type="$5"  # write, read
    
    local output_file="$RESULT_DIR/${test_name}_${rw_type}_${file_size}_bs${block_size}.json"
    
    log_test "$test_name - $rw_type - size=$file_size bs=$block_size"
    
    # 清除快取
    sync
    echo 3 > /proc/sys/vm/drop_caches
    
    fio --name="${test_name}_${rw_type}" \
        --directory="$test_dir" \
        --ioengine=libaio \
        --direct=1 \
        --rw="$rw_type" \
        --bs="$block_size" \
        --size="$file_size" \
        --numjobs=$NUMJOBS \
        --iodepth=$IODEPTH \
        --runtime=$FIO_RUNTIME \
        --time_based \
        --ramp_time=$FIO_RAMP \
        --group_reporting \
        --output-format=json \
        --output="$output_file"
    
    # 提取結果
    if [[ "$rw_type" == "write" ]]; then
        local bw=$(jq -r '.jobs[0].write.bw_bytes' "$output_file")
        local iops=$(jq -r '.jobs[0].write.iops' "$output_file")
    else
        local bw=$(jq -r '.jobs[0].read.bw_bytes' "$output_file")
        local iops=$(jq -r '.jobs[0].read.iops' "$output_file")
    fi
    
    local bw_mb=$(echo "scale=2; $bw / 1024 / 1024" | bc)
    echo "  Bandwidth: ${bw_mb} MB/s, IOPS: ${iops}"
    
    # 清理測試檔案
    rm -f "$test_dir"/*.0.*
}

#-------------------------------------------------------------------------------
# mdadm 測試
#-------------------------------------------------------------------------------
test_mdadm() {
    local raid_type="$1"
    local test_dir="/mnt/mdadm_test/$raid_type"
    
    if [[ ! -d "$test_dir" ]]; then
        log_info "目錄不存在: $test_dir，跳過"
        return
    fi
    
    log_info "===== mdadm $raid_type スループットテスト ====="
    
    for file_size in "${FILE_SIZES[@]}"; do
        for block_size in "${BLOCK_SIZES[@]}"; do
            # 寫入測試
            run_fio_throughput "mdadm_${raid_type}" "$test_dir" "$file_size" "$block_size" "write"
            
            # 讀取測試
            run_fio_throughput "mdadm_${raid_type}" "$test_dir" "$file_size" "$block_size" "read"
        done
    done
}

#-------------------------------------------------------------------------------
# ZFS 測試
#-------------------------------------------------------------------------------
test_zfs() {
    local raid_type="$1"
    local test_dir="/mnt/zfs_test/$raid_type"
    
    if [[ ! -d "$test_dir" ]]; then
        log_info "目錄不存在: $test_dir，跳過"
        return
    fi
    
    log_info "===== ZFS $raid_type スループットテスト ====="
    
    for file_size in "${FILE_SIZES[@]}"; do
        for block_size in "${BLOCK_SIZES[@]}"; do
            # 寫入測試
            run_fio_throughput "zfs_${raid_type}" "$test_dir" "$file_size" "$block_size" "write"
            
            # 讀取測試
            run_fio_throughput "zfs_${raid_type}" "$test_dir" "$file_size" "$block_size" "read"
        done
    done
}

#-------------------------------------------------------------------------------
# ZFS recordsize 比較測試
#-------------------------------------------------------------------------------
test_zfs_recordsize() {
    local pool_type="$1"
    local recordsizes=("rs4k" "rs128k" "rs1m")
    
    log_info "===== ZFS $pool_type recordsize 比較 ====="
    
    for rs in "${recordsizes[@]}"; do
        local test_dir="/mnt/zfs_test/${pool_type}/${rs}"
        
        if [[ ! -d "$test_dir" ]]; then
            continue
        fi
        
        for block_size in "${BLOCK_SIZES[@]}"; do
            run_fio_throughput "zfs_${pool_type}_${rs}" "$test_dir" "5G" "$block_size" "write"
            run_fio_throughput "zfs_${pool_type}_${rs}" "$test_dir" "5G" "$block_size" "read"
        done
    done
}

#-------------------------------------------------------------------------------
# 生成摘要報告
#-------------------------------------------------------------------------------
generate_summary() {
    local summary_file="$RESULT_DIR/throughput_summary.csv"
    
    log_info "生成摘要報告..."
    
    echo "test_name,rw_type,file_size,block_size,bandwidth_MBps,iops" > "$summary_file"
    
    for json_file in "$RESULT_DIR"/*.json; do
        [[ -f "$json_file" ]] || continue
        
        local filename=$(basename "$json_file" .json)
        
        # 解析檔名
        if [[ "$filename" =~ (.+)_(write|read)_([0-9]+[GM])_bs(.+) ]]; then
            local test_name="${BASH_REMATCH[1]}"
            local rw_type="${BASH_REMATCH[2]}"
            local file_size="${BASH_REMATCH[3]}"
            local block_size="${BASH_REMATCH[4]}"
            
            if [[ "$rw_type" == "write" ]]; then
                local bw=$(jq -r '.jobs[0].write.bw_bytes // 0' "$json_file")
                local iops=$(jq -r '.jobs[0].write.iops // 0' "$json_file")
            else
                local bw=$(jq -r '.jobs[0].read.bw_bytes // 0' "$json_file")
                local iops=$(jq -r '.jobs[0].read.iops // 0' "$json_file")
            fi
            
            local bw_mb=$(echo "scale=2; $bw / 1024 / 1024" | bc)
            
            echo "$test_name,$rw_type,$file_size,$block_size,$bw_mb,$iops" >> "$summary_file"
        fi
    done
    
    log_info "摘要已儲存: $summary_file"
    
    # 顯示摘要
    echo ""
    echo "=============================================="
    echo "スループット測試結果摘要"
    echo "=============================================="
    column -t -s',' "$summary_file"
}

#-------------------------------------------------------------------------------
# 主程式
#-------------------------------------------------------------------------------
main() {
    local target="${1:-all}"
    
    log_info "開始スループット評価測試"
    log_info "結果目錄: $RESULT_DIR"
    
    # 檢查 fio
    if ! command -v fio &> /dev/null; then
        apt update && apt install -y fio jq bc
    fi
    
    case "$target" in
        mdadm)
            test_mdadm "raid5"
            test_mdadm "raid6"
            test_mdadm "raid10"
            ;;
        zfs)
            test_zfs "raidz1"
            test_zfs "raidz2"
            test_zfs "mirror"
            ;;
        recordsize)
            test_zfs_recordsize "raidz1"
            ;;
        all)
            # mdadm 測試
            test_mdadm "raid5"
            test_mdadm "raid6"
            test_mdadm "raid10"
            
            # ZFS 測試
            test_zfs "raidz1"
            test_zfs "raidz2"
            test_zfs "mirror"
            
            # recordsize 測試
            test_zfs_recordsize "raidz1"
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
