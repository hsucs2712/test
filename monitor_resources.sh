#!/bin/bash
#===============================================================================
# monitor_resources.sh
# CPU / Memory 使用率監控腳本
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/results/resources"
INTERVAL=1

# 確保目錄存在
mkdir -p "$RESULT_DIR"

GREEN='\033[0;32m'
NC='\033[0m'
log_info() { echo -e "${GREEN}[MONITOR]${NC} $1"; }

#-------------------------------------------------------------------------------
# 開始監控
#-------------------------------------------------------------------------------
start_monitor() {
    local test_name="${1:-unknown}"
    local output_file="$RESULT_DIR/${test_name}_$(date +%Y%m%d_%H%M%S).csv"
    local pid_file="$RESULT_DIR/.monitor.pid"
    
    # 如果已經在執行，先停止
    if [[ -f "$pid_file" ]]; then
        local old_pid=$(cat "$pid_file")
        kill "$old_pid" 2>/dev/null || true
        rm -f "$pid_file"
    fi
    
    log_info "開始監控: $test_name"
    log_info "輸出檔案: $output_file"
    
    # 寫入 CSV 標頭
    echo "timestamp,cpu_percent,mem_used_mb,mem_total_mb,mem_percent,swap_used_mb,load_1m,load_5m,load_15m" > "$output_file"
    
    # 背景執行監控
    (
        while true; do
            ts=$(date '+%Y-%m-%d %H:%M:%S')
            
            # CPU（更可靠的方式）
            cpu=$(grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {printf "%.1f", usage}')
            
            # Memory
            mem_total=$(free -m | awk '/Mem:/ {print $2}')
            mem_used=$(free -m | awk '/Mem:/ {print $3}')
            mem_percent=$(awk "BEGIN {printf \"%.1f\", $mem_used*100/$mem_total}")
            
            # Swap
            swap_used=$(free -m | awk '/Swap:/ {print $3}')
            
            # Load
            read load_1 load_5 load_15 _ _ < /proc/loadavg
            
            echo "$ts,$cpu,$mem_used,$mem_total,$mem_percent,$swap_used,$load_1,$load_5,$load_15" >> "$output_file"
            
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
    local output_file_ref="$RESULT_DIR/.monitor.output"
    
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            log_info "監控已停止 (PID: $pid)"
        else
            log_info "監控進程已結束"
        fi
        
        rm -f "$pid_file"
        
        # 顯示摘要
        if [[ -f "$output_file_ref" ]]; then
            local output_file=$(cat "$output_file_ref")
            if [[ -f "$output_file" ]]; then
                local lines=$(wc -l < "$output_file")
                log_info "記錄了 $((lines-1)) 筆資料"
                log_info "檔案: $output_file"
                
                # 簡單摘要
                echo ""
                echo "=== 資源使用摘要 ==="
                awk -F',' 'NR>1 {cpu+=$2; mem+=$5; n++} END {printf "CPU 平均: %.1f%%\nMemory 平均: %.1f%%\n", cpu/n, mem/n}' "$output_file"
            fi
            rm -f "$output_file_ref"
        fi
    else
        log_info "沒有執行中的監控"
    fi
}

#-------------------------------------------------------------------------------
# 即時顯示
#-------------------------------------------------------------------------------
show_realtime() {
    log_info "即時監控（Ctrl+C 停止）"
    printf "\n%-20s %8s %12s %8s\n" "TIME" "CPU%" "MEM_USED" "MEM%"
    echo "------------------------------------------------"
    
    while true; do
        ts=$(date '+%H:%M:%S')
        cpu=$(grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {printf "%.1f", usage}')
        mem_used=$(free -m | awk '/Mem:/ {print $3}')
        mem_total=$(free -m | awk '/Mem:/ {print $2}')
        mem_percent=$(awk "BEGIN {printf \"%.1f\", $mem_used*100/$mem_total}")
        
        printf "%-20s %7s%% %10sMB %7s%%\n" "$ts" "$cpu" "$mem_used" "$mem_percent"
        sleep 1
    done
}

#-------------------------------------------------------------------------------
# 狀態檢查
#-------------------------------------------------------------------------------
check_status() {
    local pid_file="$RESULT_DIR/.monitor.pid"
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            log_info "監控執行中 (PID: $pid)"
            return 0
        fi
    fi
    log_info "監控未執行"
    return 1
}

#-------------------------------------------------------------------------------
# 主程式
#-------------------------------------------------------------------------------
case "${1:-show}" in
    start)
        start_monitor "$2"
        ;;
    stop)
        stop_monitor
        ;;
    show)
        show_realtime
        ;;
    status)
        check_status
        ;;
    *)
        echo "用法: $0 {start|stop|show|status} [test_name]"
        echo ""
        echo "  start <n>  - 開始背景監控"
        echo "  stop          - 停止監控"
        echo "  show          - 即時顯示"
        echo "  status        - 查看狀態"
        ;;
esac
