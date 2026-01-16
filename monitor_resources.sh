#!/bin/bash
#===============================================================================
# monitor_resources.sh
# CPU / Memory 使用率監控腳本
# 在測試期間背景執行，記錄系統資源使用情況
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/results/resources"
INTERVAL=1  # 取樣間隔（秒）

mkdir -p "$RESULT_DIR"

# 顏色
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[MONITOR]${NC} $1"; }

#-------------------------------------------------------------------------------
# 開始監控（背景執行）
#-------------------------------------------------------------------------------
start_monitor() {
    local test_name="${1:-unknown}"
    local output_file="$RESULT_DIR/${test_name}_$(date +%Y%m%d_%H%M%S).csv"
    local pid_file="$RESULT_DIR/.monitor.pid"
    
    log_info "開始監控: $test_name"
    log_info "輸出檔案: $output_file"
    
    # 寫入 CSV 標頭
    echo "timestamp,cpu_percent,mem_used_mb,mem_total_mb,mem_percent,swap_used_mb,load_1m,load_5m,load_15m,io_wait" > "$output_file"
    
    # 背景執行監控
    (
        while true; do
            # 時間戳
            ts=$(date '+%Y-%m-%d %H:%M:%S')
            
            # CPU 使用率（排除 idle）
            cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}')
            
            # IO Wait
            iowait=$(top -bn1 | grep "Cpu(s)" | awk '{print $10}' | tr -d ',')
            
            # Memory
            mem_info=$(free -m | grep Mem)
            mem_total=$(echo "$mem_info" | awk '{print $2}')
            mem_used=$(echo "$mem_info" | awk '{print $3}')
            mem_percent=$(echo "scale=1; $mem_used * 100 / $mem_total" | bc)
            
            # Swap
            swap_used=$(free -m | grep Swap | awk '{print $3}')
            
            # Load Average
            load=$(cat /proc/loadavg)
            load_1=$(echo "$load" | awk '{print $1}')
            load_5=$(echo "$load" | awk '{print $2}')
            load_15=$(echo "$load" | awk '{print $3}')
            
            # 寫入 CSV
            echo "$ts,$cpu,$mem_used,$mem_total,$mem_percent,$swap_used,$load_1,$load_5,$load_15,$iowait" >> "$output_file"
            
            sleep $INTERVAL
        done
    ) &
    
    # 儲存 PID
    echo $! > "$pid_file"
    echo "$output_file" > "$RESULT_DIR/.monitor.output"
    
    log_info "監控已啟動 (PID: $(cat $pid_file))"
}

#-------------------------------------------------------------------------------
# 停止監控
#-------------------------------------------------------------------------------
stop_monitor() {
    local pid_file="$RESULT_DIR/.monitor.pid"
    local output_file_path="$RESULT_DIR/.monitor.output"
    
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_info "監控已停止 (PID: $pid)"
        fi
        
        rm -f "$pid_file"
        
        # 顯示摘要
        if [[ -f "$output_file_path" ]]; then
            local output_file=$(cat "$output_file_path")
            if [[ -f "$output_file" ]]; then
                generate_summary "$output_file"
            fi
            rm -f "$output_file_path"
        fi
    else
        log_info "沒有執行中的監控"
    fi
}

#-------------------------------------------------------------------------------
# 生成摘要
#-------------------------------------------------------------------------------
generate_summary() {
    local csv_file="$1"
    local summary_file="${csv_file%.csv}_summary.txt"
    
    if [[ ! -f "$csv_file" ]]; then
        return
    fi
    
    log_info "生成資源使用摘要..."
    
    {
        echo "=============================================="
        echo "系統資源使用摘要"
        echo "=============================================="
        echo "資料檔案: $csv_file"
        echo "取樣數: $(tail -n +2 "$csv_file" | wc -l)"
        echo ""
        
        # CPU 統計
        echo "=== CPU 使用率 (%) ==="
        tail -n +2 "$csv_file" | cut -d',' -f2 | awk '
            BEGIN { min=100; max=0; sum=0; count=0 }
            {
                if ($1 < min) min=$1
                if ($1 > max) max=$1
                sum += $1
                count++
            }
            END {
                if (count > 0) {
                    printf "  Min: %.1f%%\n", min
                    printf "  Max: %.1f%%\n", max
                    printf "  Avg: %.1f%%\n", sum/count
                }
            }
        '
        
        echo ""
        
        # Memory 統計
        echo "=== Memory 使用率 (%) ==="
        tail -n +2 "$csv_file" | cut -d',' -f5 | awk '
            BEGIN { min=100; max=0; sum=0; count=0 }
            {
                if ($1 < min) min=$1
                if ($1 > max) max=$1
                sum += $1
                count++
            }
            END {
                if (count > 0) {
                    printf "  Min: %.1f%%\n", min
                    printf "  Max: %.1f%%\n", max
                    printf "  Avg: %.1f%%\n", sum/count
                }
            }
        '
        
        echo ""
        
        # IO Wait 統計
        echo "=== IO Wait (%) ==="
        tail -n +2 "$csv_file" | cut -d',' -f10 | awk '
            BEGIN { min=100; max=0; sum=0; count=0 }
            {
                if ($1 != "") {
                    if ($1 < min) min=$1
                    if ($1 > max) max=$1
                    sum += $1
                    count++
                }
            }
            END {
                if (count > 0) {
                    printf "  Min: %.1f%%\n", min
                    printf "  Max: %.1f%%\n", max
                    printf "  Avg: %.1f%%\n", sum/count
                }
            }
        '
        
        echo ""
        echo "=============================================="
        
    } > "$summary_file"
    
    cat "$summary_file"
    log_info "摘要已儲存: $summary_file"
}

#-------------------------------------------------------------------------------
# 即時顯示（不儲存）
#-------------------------------------------------------------------------------
show_realtime() {
    log_info "即時監控（Ctrl+C 停止）"
    echo ""
    printf "%-20s %8s %10s %10s %8s %8s\n" "TIME" "CPU%" "MEM_USED" "MEM_TOTAL" "MEM%" "IOWAIT"
    echo "------------------------------------------------------------------------"
    
    while true; do
        ts=$(date '+%H:%M:%S')
        cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}')
        iowait=$(top -bn1 | grep "Cpu(s)" | awk '{print $10}' | tr -d ',')
        mem_info=$(free -m | grep Mem)
        mem_total=$(echo "$mem_info" | awk '{print $2}')
        mem_used=$(echo "$mem_info" | awk '{print $3}')
        mem_percent=$(echo "scale=1; $mem_used * 100 / $mem_total" | bc)
        
        printf "%-20s %7.1f%% %8dMB %8dMB %7.1f%% %7.1f%%\n" \
            "$ts" "$cpu" "$mem_used" "$mem_total" "$mem_percent" "$iowait"
        
        sleep $INTERVAL
    done
}

#-------------------------------------------------------------------------------
# 主程式
#-------------------------------------------------------------------------------
main() {
    local action="${1:-show}"
    local test_name="${2:-test}"
    
    case "$action" in
        start)
            start_monitor "$test_name"
            ;;
        stop)
            stop_monitor
            ;;
        show)
            show_realtime
            ;;
        status)
            local pid_file="$RESULT_DIR/.monitor.pid"
            if [[ -f "$pid_file" ]] && kill -0 "$(cat $pid_file)" 2>/dev/null; then
                log_info "監控執行中 (PID: $(cat $pid_file))"
            else
                log_info "監控未執行"
            fi
            ;;
        *)
            echo "用法: $0 {start|stop|show|status} [test_name]"
            echo ""
            echo "  start <name>  - 開始背景監控"
            echo "  stop          - 停止監控並生成摘要"
            echo "  show          - 即時顯示（不儲存）"
            echo "  status        - 查看監控狀態"
            exit 1
            ;;
    esac
}

main "$@"
