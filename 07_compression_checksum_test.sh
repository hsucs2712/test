#!/bin/bash
#===============================================================================
# 07_compression_checksum_test.sh
# 圧縮・チェックサム - ZFS compression/checksum ON/OFF 効果測定
#===============================================================================

set -e

# 設定
RESULT_DIR="/home/claude/mdadm_zfs_benchmark/results/compression"
FIO_RUNTIME=60
FILE_SIZE="4G"
BLOCK_SIZE="128k"

# 壓縮演算法
COMPRESSION_ALGOS=("off" "lz4" "zstd" "gzip")

# Checksum 演算法
CHECKSUM_ALGOS=("off" "on" "sha256" "sha512")

# 資料類型
DATA_TYPES=("random" "zero" "compressible")

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_test() { echo -e "${YELLOW}[TEST]${NC} $1"; }
log_note() { echo -e "${CYAN}[NOTE]${NC} $1"; }

mkdir -p "$RESULT_DIR"

#-------------------------------------------------------------------------------
# 生成測試資料
#-------------------------------------------------------------------------------
generate_test_data() {
    local type="$1"
    local output="$2"
    local size_mb="$3"
    
    case "$type" in
        random)
            dd if=/dev/urandom of="$output" bs=1M count="$size_mb" 2>/dev/null
            ;;
        zero)
            dd if=/dev/zero of="$output" bs=1M count="$size_mb" 2>/dev/null
            ;;
        compressible)
            local pattern="This is a test pattern that will be repeated many times for compression testing. "
            yes "$pattern" | head -c "${size_mb}M" > "$output"
            ;;
    esac
}

#-------------------------------------------------------------------------------
# ZFS 壓縮測試
#-------------------------------------------------------------------------------
test_compression() {
    local pool_type="$1"
    local pool_name="testpool_${pool_type}"
    local base_dir="/mnt/zfs_test/$pool_type"
    
    if ! zpool list "$pool_name" &>/dev/null; then
        log_info "Pool 不存在: $pool_name，跳過"
        return
    fi
    
    log_info "===== ZFS $pool_type 圧縮テスト ====="
    
    for algo in "${COMPRESSION_ALGOS[@]}"; do
        local dataset="${pool_name}/compress_${algo}"
        local test_dir="${base_dir}/compress_${algo}"
        
        log_test "壓縮演算法: $algo"
        
        zfs destroy "$dataset" 2>/dev/null || true
        zfs create -o compression="$algo" "$dataset"
        
        for data_type in "${DATA_TYPES[@]}"; do
            log_test "  資料類型: $data_type"
            
            local test_file="${test_dir}/test_${data_type}"
            
            sync
            echo 3 > /proc/sys/vm/drop_caches
            
            # 寫入測試
            local start_time=$(date +%s.%N)
            generate_test_data "$data_type" "$test_file" 1024
            sync
            local end_time=$(date +%s.%N)
            
            local write_time=$(echo "$end_time - $start_time" | bc)
            local write_speed=$(echo "scale=2; 1024 / $write_time" | bc)
            
            # 壓縮比
            local logical=$(zfs get -Hp -o value logicalused "$dataset")
            local physical=$(zfs get -Hp -o value used "$dataset")
            local ratio=$(echo "scale=2; $logical / $physical" | bc 2>/dev/null || echo "1.00")
            
            # 讀取測試
            echo 3 > /proc/sys/vm/drop_caches
            start_time=$(date +%s.%N)
            dd if="$test_file" of=/dev/null bs=1M 2>/dev/null
            end_time=$(date +%s.%N)
            
            local read_time=$(echo "$end_time - $start_time" | bc)
            local read_speed=$(echo "scale=2; 1024 / $read_time" | bc)
            
            echo "    Write: ${write_speed} MB/s, Read: ${read_speed} MB/s, Ratio: ${ratio}x"
            
            cat > "$RESULT_DIR/compress_${pool_type}_${algo}_${data_type}.json" << EOF
{
    "pool_type": "$pool_type",
    "compression": "$algo",
    "data_type": "$data_type",
    "write_MBps": $write_speed,
    "read_MBps": $read_speed,
    "compression_ratio": $ratio
}
EOF
            rm -f "$test_file"
        done
        
        zfs destroy "$dataset"
    done
}

#-------------------------------------------------------------------------------
# ZFS Checksum 測試
#-------------------------------------------------------------------------------
test_checksum() {
    local pool_type="$1"
    local pool_name="testpool_${pool_type}"
    local base_dir="/mnt/zfs_test/$pool_type"
    
    if ! zpool list "$pool_name" &>/dev/null; then
        log_info "Pool 不存在: $pool_name，跳過"
        return
    fi
    
    log_info "===== ZFS $pool_type チェックサムテスト ====="
    
    for algo in "${CHECKSUM_ALGOS[@]}"; do
        local dataset="${pool_name}/checksum_${algo}"
        local test_dir="${base_dir}/checksum_${algo}"
        
        log_test "Checksum: $algo"
        
        zfs destroy "$dataset" 2>/dev/null || true
        zfs create -o checksum="$algo" -o compression=off "$dataset"
        
        sync
        echo 3 > /proc/sys/vm/drop_caches
        
        # 寫入測試
        fio --name="checksum_write" \
            --directory="$test_dir" \
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
            --output="$RESULT_DIR/checksum_${pool_type}_${algo}_write.json"
        
        local write_bw=$(jq -r '.jobs[0].write.bw_bytes' "$RESULT_DIR/checksum_${pool_type}_${algo}_write.json")
        local write_mb=$(echo "scale=2; $write_bw / 1024 / 1024" | bc)
        
        sync
        echo 3 > /proc/sys/vm/drop_caches
        
        # 讀取測試
        fio --name="checksum_read" \
            --directory="$test_dir" \
            --ioengine=libaio \
            --direct=1 \
            --rw=read \
            --bs="$BLOCK_SIZE" \
            --size="$FILE_SIZE" \
            --numjobs=1 \
            --iodepth=32 \
            --runtime=$FIO_RUNTIME \
            --time_based \
            --group_reporting \
            --output-format=json \
            --output="$RESULT_DIR/checksum_${pool_type}_${algo}_read.json"
        
        local read_bw=$(jq -r '.jobs[0].read.bw_bytes' "$RESULT_DIR/checksum_${pool_type}_${algo}_read.json")
        local read_mb=$(echo "scale=2; $read_bw / 1024 / 1024" | bc)
        
        echo "  Write: ${write_mb} MB/s, Read: ${read_mb} MB/s"
        
        rm -f "$test_dir"/*.0.*
        zfs destroy "$dataset"
    done
}

#-------------------------------------------------------------------------------
# 生成摘要
#-------------------------------------------------------------------------------
generate_summary() {
    log_info "生成摘要報告..."
    
    # 壓縮摘要
    local summary="$RESULT_DIR/compression_checksum_summary.csv"
    echo "test_type,config,data_type,write_MBps,read_MBps,ratio" > "$summary"
    
    for json_file in "$RESULT_DIR"/*.json; do
        [[ -f "$json_file" ]] || continue
        [[ "$json_file" =~ _write\.json$ ]] && continue
        [[ "$json_file" =~ _read\.json$ ]] && continue
        
        local compression=$(jq -r '.compression // "N/A"' "$json_file")
        local data_type=$(jq -r '.data_type // "N/A"' "$json_file")
        local write=$(jq -r '.write_MBps // 0' "$json_file")
        local read=$(jq -r '.read_MBps // 0' "$json_file")
        local ratio=$(jq -r '.compression_ratio // 1' "$json_file")
        
        echo "compression,$compression,$data_type,$write,$read,$ratio" >> "$summary"
    done
    
    log_info "摘要已儲存: $summary"
    
    echo ""
    echo "=============================================="
    echo "圧縮・チェックサム測試結果"
    echo "=============================================="
    column -t -s',' "$summary"
    
    echo ""
    log_note "壓縮建議:"
    echo "  - lz4: 最佳平衡（速度快、壓縮比適中）"
    echo "  - zstd: 較高壓縮比、CPU 使用略高"
    echo "  - gzip: 相容性好但速度慢"
    echo ""
    log_note "Checksum 建議:"
    echo "  - on (fletcher4): 預設、效能好"
    echo "  - sha256: 更安全、略慢"
}

#-------------------------------------------------------------------------------
# 主程式
#-------------------------------------------------------------------------------
main() {
    local target="${1:-all}"
    
    log_info "開始圧縮・チェックサム測試"
    log_info "結果目錄: $RESULT_DIR"
    
    if ! command -v fio &> /dev/null; then
        apt update && apt install -y fio jq bc
    fi
    
    case "$target" in
        compression)
            test_compression "raidz1"
            ;;
        checksum)
            test_checksum "raidz1"
            ;;
        all)
            test_compression "raidz1"
            test_checksum "raidz1"
            ;;
        summary)
            ;;
        *)
            echo "用法: $0 {compression|checksum|all|summary}"
            exit 1
            ;;
    esac
    
    generate_summary
}

main "$@"
