# Akshare Vaporwave

A 股分析桌面应用和本地 HTTP 服务。当前运行链路为 Vue 前端、Tauri 桌面壳、Zig sidecar 和 DuckDB。

## Quick Start

```bash
./server.sh start
```

```bash
./tauri-client.sh scan 100
./tauri-client.sh stock 600519
./tauri-client.sh sync stats
```

## Build

```bash
./tauri-client.sh ensure-sidecar
cd frontend && npm run build
./tauri-client.sh build
```

## Verify

```bash
bash tests/test_zig_only_project.sh
zsh -n tauri-client.sh
zsh -n server.sh
cd frontend && npm run build
```
