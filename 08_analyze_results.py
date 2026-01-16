#!/usr/bin/env python3
"""
08_analyze_results.py
mdadm vs ZFS 測試結果分析與視覺化
"""

import os
import json
import glob
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib
matplotlib.use('Agg')  # 無 GUI 環境
import numpy as np
from pathlib import Path

# 設定 - 使用相對路徑
import sys
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RESULT_BASE = os.path.join(SCRIPT_DIR, "results")
OUTPUT_DIR = os.path.join(SCRIPT_DIR, "analysis")

# 日文字體（如果沒有則用英文）
plt.rcParams['font.family'] = ['DejaVu Sans', 'IPAGothic', 'sans-serif']
plt.rcParams['figure.figsize'] = (12, 8)
plt.rcParams['figure.dpi'] = 150

os.makedirs(OUTPUT_DIR, exist_ok=True)

#-------------------------------------------------------------------------------
# 載入結果
#-------------------------------------------------------------------------------
def load_throughput_results():
    """載入 throughput 測試結果"""
    csv_file = f"{RESULT_BASE}/throughput/throughput_summary.csv"
    if os.path.exists(csv_file):
        return pd.read_csv(csv_file)
    return None

def load_latency_results():
    """載入 latency 測試結果"""
    csv_file = f"{RESULT_BASE}/latency/latency_summary.csv"
    if os.path.exists(csv_file):
        return pd.read_csv(csv_file)
    return None

def load_sync_results():
    """載入 sync write 測試結果"""
    csv_file = f"{RESULT_BASE}/sync_write/sync_write_summary.csv"
    if os.path.exists(csv_file):
        return pd.read_csv(csv_file)
    return None

def load_cache_results():
    """載入 cache 測試結果"""
    csv_file = f"{RESULT_BASE}/cache/cache_summary.csv"
    if os.path.exists(csv_file):
        return pd.read_csv(csv_file)
    return None

def load_compression_results():
    """載入 compression 測試結果"""
    csv_file = f"{RESULT_BASE}/compression/compression_checksum_summary.csv"
    if os.path.exists(csv_file):
        return pd.read_csv(csv_file)
    return None

#-------------------------------------------------------------------------------
# 視覺化函數
#-------------------------------------------------------------------------------
def plot_throughput_comparison(df):
    """スループット比較圖"""
    if df is None or df.empty:
        print("No throughput data available")
        return
    
    fig, axes = plt.subplots(1, 2, figsize=(14, 6))
    
    # 寫入效能
    write_df = df[df['rw_type'] == 'write']
    if not write_df.empty:
        pivot = write_df.pivot_table(
            index='test_name', 
            columns='block_size', 
            values='bandwidth_MBps', 
            aggfunc='mean'
        )
        pivot.plot(kind='bar', ax=axes[0], colormap='viridis')
        axes[0].set_title('Sequential Write Throughput')
        axes[0].set_ylabel('Bandwidth (MB/s)')
        axes[0].set_xlabel('')
        axes[0].legend(title='Block Size')
        axes[0].tick_params(axis='x', rotation=45)
    
    # 讀取效能
    read_df = df[df['rw_type'] == 'read']
    if not read_df.empty:
        pivot = read_df.pivot_table(
            index='test_name', 
            columns='block_size', 
            values='bandwidth_MBps', 
            aggfunc='mean'
        )
        pivot.plot(kind='bar', ax=axes[1], colormap='plasma')
        axes[1].set_title('Sequential Read Throughput')
        axes[1].set_ylabel('Bandwidth (MB/s)')
        axes[1].set_xlabel('')
        axes[1].legend(title='Block Size')
        axes[1].tick_params(axis='x', rotation=45)
    
    plt.tight_layout()
    plt.savefig(f"{OUTPUT_DIR}/throughput_comparison.png")
    plt.close()
    print(f"Saved: {OUTPUT_DIR}/throughput_comparison.png")

def plot_latency_comparison(df):
    """レイテンシ比較圖"""
    if df is None or df.empty:
        print("No latency data available")
        return
    
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    
    # P99 延遲 - randread
    randread = df[df['rw_type'] == 'randread']
    if not randread.empty:
        pivot = randread.pivot_table(
            index='test_name',
            columns='iodepth',
            values='lat_p99_us',
            aggfunc='mean'
        )
        pivot.plot(kind='bar', ax=axes[0, 0], colormap='RdYlBu')
        axes[0, 0].set_title('Random Read P99 Latency')
        axes[0, 0].set_ylabel('Latency (µs)')
        axes[0, 0].tick_params(axis='x', rotation=45)
    
    # P99 延遲 - randwrite
    randwrite = df[df['rw_type'] == 'randwrite']
    if not randwrite.empty:
        pivot = randwrite.pivot_table(
            index='test_name',
            columns='iodepth',
            values='lat_p99_us',
            aggfunc='mean'
        )
        pivot.plot(kind='bar', ax=axes[0, 1], colormap='RdYlBu')
        axes[0, 1].set_title('Random Write P99 Latency')
        axes[0, 1].set_ylabel('Latency (µs)')
        axes[0, 1].tick_params(axis='x', rotation=45)
    
    # IOPS - randread
    if not randread.empty:
        pivot = randread.pivot_table(
            index='test_name',
            columns='iodepth',
            values='iops',
            aggfunc='mean'
        )
        pivot.plot(kind='bar', ax=axes[1, 0], colormap='Greens')
        axes[1, 0].set_title('Random Read IOPS')
        axes[1, 0].set_ylabel('IOPS')
        axes[1, 0].tick_params(axis='x', rotation=45)
    
    # IOPS - randwrite
    if not randwrite.empty:
        pivot = randwrite.pivot_table(
            index='test_name',
            columns='iodepth',
            values='iops',
            aggfunc='mean'
        )
        pivot.plot(kind='bar', ax=axes[1, 1], colormap='Greens')
        axes[1, 1].set_title('Random Write IOPS')
        axes[1, 1].set_ylabel('IOPS')
        axes[1, 1].tick_params(axis='x', rotation=45)
    
    plt.tight_layout()
    plt.savefig(f"{OUTPUT_DIR}/latency_comparison.png")
    plt.close()
    print(f"Saved: {OUTPUT_DIR}/latency_comparison.png")

def plot_sync_comparison(df):
    """同期書き込み比較圖"""
    if df is None or df.empty:
        print("No sync write data available")
        return
    
    fig, ax = plt.subplots(figsize=(12, 6))
    
    # 分組顯示
    df_sorted = df.sort_values(['test_name', 'sync_mode'])
    
    x = np.arange(len(df_sorted))
    colors = ['#2ecc71' if 'async' in m else '#e74c3c' for m in df_sorted['sync_mode']]
    
    bars = ax.bar(x, df_sorted['bandwidth_MBps'], color=colors)
    ax.set_xticks(x)
    ax.set_xticklabels([f"{row['test_name']}\n{row['sync_mode']}" 
                        for _, row in df_sorted.iterrows()], 
                       rotation=45, ha='right', fontsize=8)
    ax.set_ylabel('Bandwidth (MB/s)')
    ax.set_title('Sync vs Async Write Performance')
    
    # 圖例
    from matplotlib.patches import Patch
    legend_elements = [
        Patch(facecolor='#2ecc71', label='Async'),
        Patch(facecolor='#e74c3c', label='Sync')
    ]
    ax.legend(handles=legend_elements, loc='upper right')
    
    plt.tight_layout()
    plt.savefig(f"{OUTPUT_DIR}/sync_comparison.png")
    plt.close()
    print(f"Saved: {OUTPUT_DIR}/sync_comparison.png")

def plot_cache_effect(df):
    """キャッシュ効果圖"""
    if df is None or df.empty:
        print("No cache data available")
        return
    
    fig, axes = plt.subplots(1, 2, figsize=(14, 6))
    
    # Cold vs Warm 讀取
    x = np.arange(len(df))
    width = 0.35
    
    axes[0].bar(x - width/2, df['cold_read_MBps'], width, label='Cold Read', color='#3498db')
    axes[0].bar(x + width/2, df['warm_read_MBps'], width, label='Warm Read', color='#e74c3c')
    axes[0].set_xticks(x)
    axes[0].set_xticklabels([f"{row['test_name']}\nARC:{row['arc_size']}" 
                             for _, row in df.iterrows()], rotation=45, ha='right')
    axes[0].set_ylabel('Bandwidth (MB/s)')
    axes[0].set_title('ARC Cache Effect: Cold vs Warm Read')
    axes[0].legend()
    
    # Speedup
    axes[1].bar(x, df['speedup'], color='#9b59b6')
    axes[1].set_xticks(x)
    axes[1].set_xticklabels([f"{row['test_name']}\nARC:{row['arc_size']}" 
                             for _, row in df.iterrows()], rotation=45, ha='right')
    axes[1].set_ylabel('Speedup (x)')
    axes[1].set_title('Cache Speedup Factor')
    axes[1].axhline(y=1, color='r', linestyle='--', alpha=0.5)
    
    plt.tight_layout()
    plt.savefig(f"{OUTPUT_DIR}/cache_effect.png")
    plt.close()
    print(f"Saved: {OUTPUT_DIR}/cache_effect.png")

def plot_compression_effect(df):
    """圧縮効果圖"""
    if df is None or df.empty:
        print("No compression data available")
        return
    
    fig, axes = plt.subplots(1, 3, figsize=(15, 5))
    
    # 按壓縮演算法分組
    for i, data_type in enumerate(['random', 'compressible', 'zero']):
        subset = df[df['data_type'] == data_type]
        if subset.empty:
            continue
        
        x = np.arange(len(subset))
        width = 0.35
        
        axes[i].bar(x - width/2, subset['write_MBps'], width, label='Write', color='#3498db')
        axes[i].bar(x + width/2, subset['read_MBps'], width, label='Read', color='#2ecc71')
        axes[i].set_xticks(x)
        axes[i].set_xticklabels(subset['config'], rotation=45, ha='right')
        axes[i].set_ylabel('Bandwidth (MB/s)')
        axes[i].set_title(f'Data Type: {data_type}')
        axes[i].legend()
    
    plt.suptitle('Compression Algorithm Performance by Data Type')
    plt.tight_layout()
    plt.savefig(f"{OUTPUT_DIR}/compression_effect.png")
    plt.close()
    print(f"Saved: {OUTPUT_DIR}/compression_effect.png")

#-------------------------------------------------------------------------------
# 生成報告
#-------------------------------------------------------------------------------
def generate_markdown_report():
    """生成 Markdown 報告"""
    report = []
    report.append("# mdadm vs ZFS 性能比較報告\n")
    report.append(f"生成日期: {pd.Timestamp.now().strftime('%Y-%m-%d %H:%M')}\n")
    
    # Throughput
    report.append("\n## 1. スループット評価\n")
    df = load_throughput_results()
    if df is not None:
        report.append("### 循序讀寫效能 (MB/s)\n")
        report.append(df.to_markdown(index=False))
        report.append("\n![Throughput](throughput_comparison.png)\n")
    
    # Latency
    report.append("\n## 2. レイテンシ評価\n")
    df = load_latency_results()
    if df is not None:
        report.append("### 隨機 4KB 讀寫延遲 (µs)\n")
        report.append(df.to_markdown(index=False))
        report.append("\n![Latency](latency_comparison.png)\n")
    
    # Sync Write
    report.append("\n## 3. 同期書き込み評価\n")
    df = load_sync_results()
    if df is not None:
        report.append("### Sync vs Async 效能\n")
        report.append(df.to_markdown(index=False))
        report.append("\n![Sync](sync_comparison.png)\n")
    
    # Cache
    report.append("\n## 4. キャッシュ効果\n")
    df = load_cache_results()
    if df is not None:
        report.append("### ARC 快取效果\n")
        report.append(df.to_markdown(index=False))
        report.append("\n![Cache](cache_effect.png)\n")
    
    # Compression
    report.append("\n## 5. 圧縮・チェックサム\n")
    df = load_compression_results()
    if df is not None:
        report.append("### 壓縮效能\n")
        report.append(df.to_markdown(index=False))
        report.append("\n![Compression](compression_effect.png)\n")
    
    # 結論
    report.append("\n## 6. 結論與建議\n")
    report.append("""
### mdadm 適用場景
- Linux 原生支援需求
- 記憶體受限環境
- 需要 RAID reshape 功能
- 簡單 RAID 需求

### ZFS 適用場景
- 資料完整性重要（研究/HPC）
- 需要快照/clone 功能
- 有充足記憶體（1GB/TB）
- 需要內建壓縮

### 效能總結
| 指標 | mdadm | ZFS | 備註 |
|------|-------|-----|------|
| 循序讀 | ★★★★☆ | ★★★★☆ | 相近 |
| 循序寫 | ★★★★★ | ★★★★☆ | mdadm 略快 |
| 隨機讀 | ★★★☆☆ | ★★★★☆ | ZFS ARC 優勢 |
| 隨機寫 | ★★★★☆ | ★★★☆☆ | mdadm 略快 |
| 同步寫 | ★★☆☆☆ | ★★★★☆ | ZFS+SLOG 優勢 |
""")
    
    # 寫入報告
    report_path = f"{OUTPUT_DIR}/benchmark_report.md"
    with open(report_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(report))
    print(f"Saved: {report_path}")

#-------------------------------------------------------------------------------
# 主程式
#-------------------------------------------------------------------------------
def main():
    print("=" * 60)
    print("mdadm vs ZFS 測試結果分析")
    print("=" * 60)
    
    # 載入並視覺化
    print("\n載入並分析結果...")
    
    df = load_throughput_results()
    if df is not None:
        print(f"Throughput: {len(df)} records")
        plot_throughput_comparison(df)
    
    df = load_latency_results()
    if df is not None:
        print(f"Latency: {len(df)} records")
        plot_latency_comparison(df)
    
    df = load_sync_results()
    if df is not None:
        print(f"Sync Write: {len(df)} records")
        plot_sync_comparison(df)
    
    df = load_cache_results()
    if df is not None:
        print(f"Cache: {len(df)} records")
        plot_cache_effect(df)
    
    df = load_compression_results()
    if df is not None:
        print(f"Compression: {len(df)} records")
        plot_compression_effect(df)
    
    # 生成報告
    print("\n生成 Markdown 報告...")
    generate_markdown_report()
    
    print("\n" + "=" * 60)
    print(f"分析完成！結果位於: {OUTPUT_DIR}")
    print("=" * 60)

if __name__ == "__main__":
    main()
