# Akshare A股分析应用

这是一个基于 Tauri、Vue、Zig sidecar 和 DuckDB 的 A 股分析工具，支持个股分析、技术指标、行业对比、期货联动、市场扫描、数据同步、调度任务和多因子回测。

## 当前架构

- 前端：`frontend/`，Vue + Vite。
- 桌面端：`src-tauri/`，启动并管理 Zig sidecar。
- 后端：`zig/src/main.zig`，提供 HTTP API、同步任务、调度任务和 CLI 所需接口。
- 数据层：DuckDB，本地文件默认为 `market_data.db`。
- 构建脚本：`tauri-client.sh` 负责 sidecar 编译、App 构建、同步、调度和命令行请求。

## 使用方式

### 启动浏览器开发模式

```bash
./server.sh start
```

服务启动后：

- 前端：http://127.0.0.1:5173
- Zig API：http://127.0.0.1:8000

### 启动桌面应用

```bash
./tauri-client.sh start
```

### 构建 sidecar 或应用

```bash
./tauri-client.sh ensure-sidecar
./tauri-client.sh build
```

### 数据同步

```bash
./tauri-client.sh sync stats
./tauri-client.sh sync backfill --years 10 --limit 50
./tauri-client.sh sync update --limit 200
```

### 命令行分析

```bash
# 扫描成交量靠前股票
./tauri-client.sh scan 100

# 获取单股完整分析
./tauri-client.sh stock 600519

# 使用 JSON 请求运行同步回测
./tauri-client.sh backtest request.json
```

CLI 输出原始 JSON，便于后续用 shell 管道、编辑器或其他工具处理。

## HTTP API

Zig sidecar 提供的主要接口：

- `GET /api/health`
- `GET /api/scan?top_n=100`
- `POST /api/scan/run?top_n=100`
- `GET /api/scan/history`
- `GET /api/scan/history/{date}`
- `GET /api/stock/search?q=600519`
- `GET /api/stock/{symbol}/basic`
- `GET /api/stock/{symbol}/profile`
- `GET /api/stock/{symbol}/technical`
- `GET /api/stock/{symbol}/valuation`
- `GET /api/stock/{symbol}/industry`
- `GET /api/stock/{symbol}/full`
- `GET /api/daily-k/{symbol}`
- `GET /api/factors`
- `POST /api/backtest`
- `POST /api/backtest/tasks`
- `GET /api/backtest/tasks`
- `GET /api/backtest/tasks/{task_id}`
- `POST /api/backtest/tasks/{task_id}/cancel`
- `GET /api/backtest/history`

## 回测能力

已支持的因子：

- `momentum_20d`
- `momentum_60d`
- `momentum_120d`
- `pe_percentile`
- `price_percentile`
- `volatility_20d`
- `volume_change`
- `rsi_14`
- `ma_deviation_20`

回测结果包含净值、回撤、基准和超额收益、持仓明细、换手率、交易成本、IC 分析、五分组收益、数据质量检查和任务进度。

## 验证命令

```bash
bash tests/test_zig_only_project.sh
zsh -n tauri-client.sh
zsh -n server.sh
cd frontend && npm run build
./tauri-client.sh ensure-sidecar
```

## 免责声明

本工具基于公开数据进行分析，仅供研究和学习参考，不构成投资建议。股市有风险，投资需谨慎。
