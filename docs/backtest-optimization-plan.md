# 回测系统优化记录

本文档记录当前回测系统的已落地能力和后续优化方向。当前默认实现为 Zig sidecar，前端、CLI、调度任务和桌面应用都通过同一套 HTTP API 访问。

## 当前结论

回测系统已具备以下能力：

- 本地 DuckDB 行情和股票信息缓存。
- 动态或静态股票池构建。
- 多因子横截面 rank 标准化。
- 真实调仓周期年化指标。
- 批量读取行情。
- 交易成本、滑点、涨跌停、停牌和新股过滤。
- 基准收益、超额收益、信息比率。
- 持仓明细、换手率、因子 IC、五分组收益。
- 因子缓存、结果缓存、任务队列、任务取消和任务状态持久化。
- 浏览器开发模式、Tauri release 和 CLI 均走 Zig sidecar。

## 数据前提

本地 `market_data.db` 包含：

- `daily_k`
- `stock_info`
- `sync_log`
- `factor_daily`
- `scan_result`
- `scan_stock`
- `job_config`
- `job_run_log`

历史数据覆盖范围以本地库实际数据为准，API 返回会包含有效数据区间和数据质量报告。

## 已完成优化

| 状态 | 优化项 | 主要位置 |
|------|--------|----------|
| DONE | 年化收益和夏普使用真实调仓周期 | `zig/src/backtest.zig` |
| DONE | 多因子横截面标准化 | `zig/src/backtest.zig` |
| DONE | 股票池改为本地历史口径 | `zig/src/backtest.zig`, `zig/src/sync.zig` |
| DONE | DuckDB 批量读取行情 | `zig/src/backtest.zig` |
| DONE | 前端展示累计净值和回撤数据 | `frontend/src/views/Backtest.vue` |
| DONE | 持仓明细和换手率 | `zig/src/backtest.zig`, `frontend/src/views/Backtest.vue` |
| DONE | 交易成本和滑点 | `zig/src/backtest.zig`, `frontend/src/views/Backtest.vue` |
| DONE | 基准和超额收益 | `zig/src/backtest.zig`, `frontend/src/views/Backtest.vue` |
| DONE | 涨跌停、停牌、新股过滤 | `zig/src/backtest.zig` |
| DONE | 因子缓存表 | `zig/src/main.zig`, `zig/src/backtest.zig` |
| DONE | 数据质量和时间顺序检查 | `zig/src/backtest.zig` |
| DONE | 原生异步任务接口 | `zig/src/main.zig`, `zig/src/backtest.zig` |
| DONE | 回测结果缓存和同参任务去重 | `zig/src/main.zig` |
| DONE | 回测任务并发控制和排队 | `zig/src/main.zig` |
| DONE | 回测任务持久化和刷新恢复 | `zig/src/main.zig`, `frontend/src/views/Backtest.vue` |
| DONE | Tauri sidecar 打包同步和 DuckDB 写锁治理 | `tauri-client.sh`, `server.sh`, `src-tauri/tauri.conf.json` |
| DONE | 浏览器开发模式切换到 Zig sidecar | `server.sh`, `tauri-client.sh`, `frontend/vite.config.ts` |
| DONE | 命令行入口切换到 `tauri-client.sh` | `tauri-client.sh` |

## 当前运行入口

```bash
./server.sh start
./tauri-client.sh start
./tauri-client.sh scan 100
./tauri-client.sh stock 600519
./tauri-client.sh backtest request.json
./tauri-client.sh sync update --limit 200
./tauri-client.sh scheduler start
```

## 后续优化方向

1. 增加更丰富的基准指数口径，如沪深300、中证500、中证1000。
2. 增加因子相关性矩阵、行业中性化和市值中性化。
3. 增加样本内/样本外切分。
4. 为 `tauri-client.sh backtest` 增加请求模板示例。
5. 为 sidecar HTTP API 增加更细粒度的 Zig 单元或集成测试。

## 验证建议

每次修改后至少执行：

```bash
bash tests/test_zig_only_project.sh
zsh -n tauri-client.sh
zsh -n server.sh
cd frontend && npm run build
./tauri-client.sh ensure-sidecar
```
