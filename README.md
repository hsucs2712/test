# mdadm vs ZFS 比較測試框架

## 測試項目

1. **スループット評価** - 循序讀寫效能
2. **レイテンシ評価** - 隨機 4KB 讀寫延遲
3. **同期書き込み評価** - sync 模式比較
4. **キャッシュ効果** - ARC 快取效果
5. **圧縮・チェックサム** - 壓縮與校驗影響

## 測試環境需求

- Ubuntu 22.04/24.04
- mdadm + ZFS 已安裝
- 至少 4 顆硬碟
- fio, iozone 已安裝

## 使用方法

```bash
# 1. 設定測試環境
sudo ./01_setup_mdadm.sh
sudo ./02_setup_zfs.sh

# 2. 執行測試
sudo ./03_throughput_test.sh
sudo ./04_latency_test.sh
sudo ./05_sync_write_test.sh
sudo ./06_cache_test.sh
sudo ./07_compression_checksum_test.sh

# 3. 分析結果
python3 08_analyze_results.py
```
