#!/bin/bash
#===============================================================================
# 06_cache_test.sh
# キャッシュ効果 - ZFS ARC サイズ変更による性能変化測定
# 使用 iozone 和 fio 測試不同 ARC 大小的效果
#===============================================================================

set -e

# 設定
RESULT_DIR="/home/claude/mdadm_zfs_benchmark/results/cache"
FIO_RUNTIME=60
FILE_SIZE="8G"

# ARC 大小設定 (bytes)
# 注意：需要足夠的系統記憶體
ARC_SIZES=("1073741824" "4294967296" "8589934592")  # 1GB, 4GB, 8GB
ARC_SIZE_NAMES=("1GB" "4GB" "8GB")

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_test() { echo -e "${YELLOW}[TEST]${NC} $1"; }
log_note() { echo -e "${CYAN}[NOTE]${NC} $1"; }

mkdir -p "$RESULT_DIR"

#-------------------------------------------------------------------------------
# 安裝依賴
#-------------------------------------------------------------------------------
install_deps() {
    if ! command -v iozone &> /dev/null; then
        log_info "安裝 iozone..."
        apt update && apt install -y iozone3
    fi
    
    if ! command -v fio &> /dev/null; then
        apt install -y fio jq bc
    fi
}

#-------------------------------------------------------------------------------
# 顯示當前 ARC 狀態
#-------------------------------------------------------------------------------
show_arc_status() {
    echo ""
    echo "=== ARC 狀態 ==="
    
    if [[ -f /proc/spl/kstat/zfs/arcstats ]]; then
        local arc_size=$(awk '/^size / {print $3}' /proc/spl/kstat/zfs/arcstats)
        local arc_max=$(cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || echo "N/A")
        local arc_min=$(cat /sys/module/zfs/parameters/zfs_arc_min 2>/dev/null || echo "N/A")
        local arc_hits=$(awk '/^hits / {print $3}' /proc/spl/kstat/zfs/arcstats)
        local arc_misses=$(awk '/^misses / {print $3}' /proc/spl/kstat/zfs/arcstats)
        
        local arc_size_gb=$(echo "scale=2; $arc_size / 1024 / 1024 / 1024" | bc)
        local arc_max_gb=$(echo "scale=2; $arc_max / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "N/A")
        
        echo "  Current Size: ${arc_size_gb} GB"
        echo "  Max Size: ${arc_max_gb} GB"
        echo "  Hits: $arc_hits"
        echo "  Misses: $arc_misses"
        
        if [[ "$arc_hits" -gt 0 ]] && [[ "$arc_misses" -gt 0 ]]; then
            local hit_rate=$(echo "scale=2; $arc_hits * 100 / ($arc_hits + $arc_misses)" | bc)
            echo "  Hit Rate: ${hit_rate}%"
        fi
    else
        echo "  ZFS ARC stats 不可用"
    fi
    echo ""
}

#-------------------------------------------------------------------------------
# 設定 ARC 大小
#-------------------------------------------------------------------------------
set_arc_size() {
    local arc_max="$1"
    
    log_info "設定 ARC max size: $arc_max bytes"
    
    # 清除 ARC
    echo 3 > /proc/sys/vm/drop_caches
    
    # 設定 ARC 大小
    echo "$arc_max" > /sys/module/zfs/parameters/zfs_arc_max
    
    # 等待 ARC 調整
    sleep 5
    
    show_arc_status
}

#-------------------------------------------------------------------------------
# 重置 ARC 為預設值
#-------------------------------------------------------------------------------
reset_arc() {
    log_info "重置 ARC 為預設值..."
    
    # 設定為 0 讓 ZFS 自動管理
    echo 0 > /sys/module/zfs/parameters/zfs_arc_max
    
    sleep 3
    show_arc_status
}

#-------------------------------------------------------------------------------
# ARC 快取效果測試 (重複讀取)
#-------------------------------------------------------------------------------
test_arc_cache_effect() {
    local pool_type="$1"
    local test_dir="/mnt/zfs_test/$pool_type"
    
    if [[ ! -d "$test_dir" ]]; then
        log_info "目錄不存在: $test_dir，跳過"
        return
    fi
    
    log_info "===== ZFS $pool_type ARC キャッシュ効果テスト ====="
    
    local test_file="$test_dir/cache_test_file"
    
    # 建立測試檔案
    log_test "建立測試檔案 (4GB)..."
    dd if=/dev/urandom of="$test_file" bs=1M count=4096 status=progress 2>/dev/null
    sync
    
    for i in "${!ARC_SIZES[@]}"; do
        local arc_size="${ARC_SIZES[$i]}"
        local arc_name="${ARC_SIZE_NAMES[$i]}"
        
        log_test "測試 ARC size: $arc_name"
        
        # 設定 ARC 大小
        set_arc_size "$arc_size"
        
        # 清除快取
        echo 3 > /proc/sys/vm/drop_caches
        
        # 記錄開始時的 ARC stats
        local arc_hits_before=$(awk '/^hits / {print $3}' /proc/spl/kstat/zfs/arcstats)
        local arc_misses_before=$(awk '/^misses / {print $3}' /proc/spl/kstat/zfs/arcstats)
        
        # 第一次讀取 (cold cache)
        log_test "First read (cold cache)..."
        local start_time=$(date +%s.%N)
        dd if="$test_file" of=/dev/null bs=1M 2>/dev/null
        local end_time=$(date +%s.%N)
        local cold_time=$(echo "$end_time - $start_time" | bc)
        local cold_speed=$(echo "scale=2; 4096 / $cold_time" | bc)
        
        echo "  Cold read: ${cold_speed} MB/s (${cold_time}s)"
        
        # 第二次讀取 (warm cache)
        log_test "Second read (warm cache)..."
        start_time=$(date +%s.%N)
        dd if="$test_file" of=/dev/null bs=1M 2>/dev/null
        end_time=$(date +%s.%N)
        local warm_time=$(echo "$end_time - $start_time" | bc)
        local warm_speed=$(echo "scale=2; 4096 / $warm_time" | bc)
        
        echo "  Warm read: ${warm_speed} MB/s (${warm_time}s)"
        
        # 記錄結束時的 ARC stats
        local arc_hits_after=$(awk '/^hits / {print $3}' /proc/spl/kstat/zfs/arcstats)
        local arc_misses_after=$(awk '/^misses / {print $3}' /proc/spl/kstat/zfs/arcstats)
        
        local new_hits=$((arc_hits_after - arc_hits_before))
        local new_misses=$((arc_misses_after - arc_misses_before))
        
        echo "  New ARC Hits: $new_hits, Misses: $new_misses"
        
        # 計算加速比
        local speedup=$(echo "scale=2; $warm_speed / $cold_speed" | bc)
        echo "  Speedup: ${speedup}x"
        
        # 儲存結果
        cat > "$RESULT_DIR/arc_${pool_type}_${arc_name}.json" << EOF
{
    "pool_type": "$pool_type",
    "arc_size": "$arc_name",
    "arc_size_bytes": $arc_size,
    "cold_read_MBps": $cold_speed,
    "warm_read_MBps": $warm_speed,
    "speedup": $speedup,
    "arc_hits": $new_hits,
    "arc_misses": $new_misses
}
EOF
    done
    
    # 清理
    rm -f "$test_file"
    reset_arc
}

#-------------------------------------------------------------------------------
# iozone 測試
#-------------------------------------------------------------------------------
test_iozone() {
    local pool_type="$1"
    local test_dir="/mnt/zfs_test/$pool_type"
    
    if [[ ! -d "$test_dir" ]]; then
        log_info "目錄不存在: $test_dir，跳過"
        return
    fi
    
    log_info "===== ZFS $pool_type iozone テスト ====="
    
    for i in "${!ARC_SIZES[@]}"; do
        local arc_size="${ARC_SIZES[$i]}"
        local arc_name="${ARC_SIZE_NAMES[$i]}"
        
        log_test "iozone with ARC size: $arc_name"
        
        set_arc_size "$arc_size"
        echo 3 > /proc/sys/vm/drop_caches
        
        # iozone 自動測試
        # -a: 自動模式
        # -g: 最大檔案大小
        # -n: 最小檔案大小
        # -f: 測試檔案位置
        # -b: 輸出 Excel 格式
        iozone -a \
            -n 64m \
            -g 2g \
            -f "$test_dir/iozone_test" \
            -b "$RESULT_DIR/iozone_${pool_type}_arc${arc_name}.xls" \
            -R \
            2>&1 | tee "$RESULT_DIR/iozone_${pool_type}_arc${arc_name}.log"
        
        rm -f "$test_dir/iozone_test"
    done
    
    reset_arc
}

#-------------------------------------------------------------------------------
# mdadm vs ZFS 快取比較 (page cache vs ARC)
#-------------------------------------------------------------------------------
compare_cache_systems() {
    log_info "===== mdadm vs ZFS キャッシュ比較 ====="
    
    local mdadm_dir="/mnt/mdadm_test/raid10"
    local zfs_dir="/mnt/zfs_test/mirror"
    local test_size="2G"
    
    # mdadm (使用 Linux page cache)
    if [[ -d "$mdadm_dir" ]]; then
        log_test "mdadm + page cache"
        
        local test_file="$mdadm_dir/cache_compare"
        
        # 建立測試檔案
        dd if=/dev/urandom of="$test_file" bs=1M count=2048 status=progress 2>/dev/null
        sync
        
        # Cold read
        echo 3 > /proc/sys/vm/drop_caches
        local start=$(date +%s.%N)
        dd if="$test_file" of=/dev/null bs=1M 2>/dev/null
        local end=$(date +%s.%N)
        local mdadm_cold=$(echo "scale=2; 2048 / ($end - $start)" | bc)
        
        # Warm read
        start=$(date +%s.%N)
        dd if="$test_file" of=/dev/null bs=1M 2>/dev/null
        end=$(date +%s.%N)
        local mdadm_warm=$(echo "scale=2; 2048 / ($end - $start)" | bc)
        
        echo "  mdadm Cold: ${mdadm_cold} MB/s, Warm: ${mdadm_warm} MB/s"
        
        rm -f "$test_file"
    fi
    
    # ZFS (使用 ARC)
    if [[ -d "$zfs_dir" ]]; then
        log_test "ZFS + ARC"
        
        local test_file="$zfs_dir/cache_compare"
        
        # 建立測試檔案
        dd if=/dev/urandom of="$test_file" bs=1M count=2048 status=progress 2>/dev/null
        sync
        
        # Cold read
        echo 3 > /proc/sys/vm/drop_caches
        local start=$(date +%s.%N)
        dd if="$test_file" of=/dev/null bs=1M 2>/dev/null
        local end=$(date +%s.%N)
        local zfs_cold=$(echo "scale=2; 2048 / ($end - $start)" | bc)
        
        # Warm read
        start=$(date +%s.%N)
        dd if="$test_file" of=/dev/null bs=1M 2>/dev/null
        end=$(date +%s.%N)
        local zfs_warm=$(echo "scale=2; 2048 / ($end - $start)" | bc)
        
        echo "  ZFS Cold: ${zfs_cold} MB/s, Warm: ${zfs_warm} MB/s"
        
        rm -f "$test_file"
    fi
}

#-------------------------------------------------------------------------------
# 生成摘要
#-------------------------------------------------------------------------------
generate_summary() {
    local summary_file="$RESULT_DIR/cache_summary.csv"
    
    log_info "生成快取測試摘要..."
    
    echo "test_name,arc_size,cold_read_MBps,warm_read_MBps,speedup,arc_hits,arc_misses" > "$summary_file"
    
    for json_file in "$RESULT_DIR"/arc_*.json; do
        [[ -f "$json_file" ]] || continue
        
        local pool_type=$(jq -r '.pool_type' "$json_file")
        local arc_size=$(jq -r '.arc_size' "$json_file")
        local cold=$(jq -r '.cold_read_MBps' "$json_file")
        local warm=$(jq -r '.warm_read_MBps' "$json_file")
        local speedup=$(jq -r '.speedup' "$json_file")
        local hits=$(jq -r '.arc_hits' "$json_file")
        local misses=$(jq -r '.arc_misses' "$json_file")
        
        echo "zfs_$pool_type,$arc_size,$cold,$warm,$speedup,$hits,$misses" >> "$summary_file"
    done
    
    log_info "摘要已儲存: $summary_file"
    
    echo ""
    echo "=============================================="
    echo "キャッシュ効果測試結果摘要"
    echo "=============================================="
    column -t -s',' "$summary_file"
    
    echo ""
    log_note "ARC 說明:"
    echo "  - ARC (Adaptive Replacement Cache) 是 ZFS 的記憶體快取"
    echo "  - 較大的 ARC 可提供更好的快取效果"
    echo "  - 建議 ARC 大小：總記憶體的 50-75%"
    echo "  - 生產環境建議：1GB per 1TB 儲存空間"
}

#-------------------------------------------------------------------------------
# 主程式
#-------------------------------------------------------------------------------
main() {
    local target="${1:-all}"
    
    log_info "開始キャッシュ効果測試"
    log_info "結果目錄: $RESULT_DIR"
    
    install_deps
    
    case "$target" in
        arc)
            test_arc_cache_effect "raidz1"
            test_arc_cache_effect "mirror"
            ;;
        iozone)
            test_iozone "raidz1"
            ;;
        compare)
            compare_cache_systems
            ;;
        all)
            show_arc_status
            test_arc_cache_effect "raidz1"
            test_arc_cache_effect "mirror"
            compare_cache_systems
            ;;
        status)
            show_arc_status
            ;;
        summary)
            ;;
        *)
            echo "用法: $0 {arc|iozone|compare|all|status|summary}"
            exit 1
            ;;
    esac
    
    generate_summary
}

main "$@"
