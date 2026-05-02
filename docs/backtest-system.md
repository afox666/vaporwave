# 回测系统架构与数据流转

## 整体架构

系统只有一条默认后端链路：

```text
Tauri release: 前端 Backtest.vue -> Zig sidecar -> DuckDB / 远端公开数据接口
浏览器开发模式: 前端 Backtest.vue -> Vite proxy -> Zig sidecar -> DuckDB / 远端公开数据接口
CLI: tauri-client.sh -> Zig sidecar HTTP API -> DuckDB / 远端公开数据接口
```

Tauri dev/build 会先执行 `./tauri-client.sh ensure-sidecar`，确保 `zig/src/*.zig` 更新后自动编译并同步到 `src-tauri/sidecars/`。浏览器开发模式由 `server.sh` 启动 `./tauri-client.sh serve 8000`，Vite 将 `/api` 代理到 `http://127.0.0.1:8000`。

## 前端请求

`frontend/src/views/Backtest.vue` 通过 `frontend/src/api/index.ts` 优先发送 `POST /api/backtest/tasks` 创建异步任务，并轮询 `GET /api/backtest/tasks/{task_id}` 获取阶段进度和最终结果。同步回测仍由 `POST /api/backtest` 提供。

主要参数包括：

- `factors`：如 `momentum_20d`、`pe_percentile`、`rsi_14`。
- `start_date` / `end_date`：回测区间。
- `rebalance_period`：调仓周期。
- `top_pct` / `bottom_pct`：多空分位。
- `pool_size` / `pool_mode` / `industry`：股票池配置。
- `commission_rate` / `stamp_tax_rate` / `slippage_rate`：交易成本。
- `min_amount` / `min_listed_days` / `limit_pct`：交易约束。
- `execution_price`：成交口径，默认 `next_open`。

## Sidecar API

`zig/src/main.zig` 提供以下回测接口：

- `POST /api/backtest`
- `POST /api/backtest/tasks`
- `GET /api/backtest/tasks`
- `GET /api/backtest/tasks/{task_id}`
- `POST /api/backtest/tasks/{task_id}/cancel`
- `GET /api/backtest/history`
- `GET /api/factors`

任务接口会处理结果缓存、同参任务去重、队列、取消和任务状态持久化。已完成任务可在 sidecar 重启后继续查询；未完成任务会标记为 `failed/interrupted`，避免前端误判仍在运行。

## 回测流程

`zig/src/backtest.zig` 的核心流程：

1. 解析并校验请求参数。
2. 根据因子计算 lookback 区间。
3. 生成调仓日期。
4. 基于 DuckDB 历史成交额构建静态或动态股票池。
5. 批量读取本地日 K 数据。
6. 按需读取估值数据并计算因子。
7. 读取和写入 `factor_daily` 因子缓存。
8. 构建多空组合，计算换手、交易成本、基准和超额收益。
9. 计算组合指标、IC、五分组收益和数据质量报告。
10. 写入 `.backtest_history/` 并返回 JSON。

## 数据层

DuckDB 主要表：

- `daily_k`：本地日 K。
- `stock_info`：股票代码和名称。
- `sync_log`：同步进度。
- `factor_daily`：因子缓存。
- `scan_result` / `scan_stock`：市场扫描历史。
- `job_config` / `job_run_log`：调度任务配置和执行记录。

行情和扫描优先使用本地库；缺失时 Zig sidecar 会通过公开数据接口补足或降级。

## 返回结构

`BacktestResult` 包含：

- `config`：请求参数、股票池来源、数据覆盖范围、缓存统计。
- `metrics`：总收益、年化收益、最大回撤、夏普、基准和超额指标。
- `portfolio`：每期收益、净值、回撤、成本、换手、持仓明细。
- `ic_analysis`：因子 IC 均值、标准差、ICIR 和正比例。
- `factor_research`：IC 时间序列和五分组收益。
- `data_quality`：行情覆盖、样本有效率和时间顺序检查。

## 命令行入口

```bash
./tauri-client.sh scan 100
./tauri-client.sh stock 600519
./tauri-client.sh backtest request.json
```

这些命令会复用正在运行的 `127.0.0.1:8000` sidecar；如果没有运行中的服务，则启动临时 sidecar，请求完成后关闭。
