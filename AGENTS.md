# Vaporwave – A股分析应用

Tauri + Vue + Zig sidecar + DuckDB. 个股分析、技术指标、行业对比、市场扫描、数据同步、回测。

## 架构

- **前端**: `frontend/` — Vue 3 + Vite + TypeScript, dev port 5173, Vite proxies `/api` → `localhost:8000`
- **桌面壳**: `src-tauri/` — Tauri v2, 启动/管理 Zig sidecar
- **后端**: `zig/src/main.zig` — single-binary HTTP API + sync scheduler + CLI, reads `market_data.db` (DuckDB)
- **Shell**: `server.sh` (dev mode 启动前后端), `tauri-client.sh` (构建/同步/CLI/scheduler, **zsh-only**)

## 开发命令

```bash
./server.sh start            # 启动前后端 (foreground, 按 Ctrl+C 停止)
./server.sh stop             # 关闭
./server.sh restart|status   # 重启/查看状态

cd frontend && npm run dev   # 仅前端 (后端需另起)
./tauri-client.sh serve 8000 # 仅后端 (前台)

./tauri-client.sh ensure-sidecar  # 编译/同步 sidecar (源码更新时自动重建)
./tauri-client.sh build           # 完整 release 构建
```

**zsh 必须**: `server.sh` 和 `tauri-client.sh` 使用 zsh 特有语法 (`{0:A:h}`, `print -r`)，不能用 bash 运行。

**DuckDB 依赖**: 需要 homebrew 安装的 `libduckdb.dylib` (`/opt/homebrew/opt/duckdb/lib` 或 `/usr/local/opt/duckdb/lib`)。

**写锁冲突**: `server.sh start` 会自动调用 `tauri-client.sh dev-unlock-db` 停止可能持有写锁的 scheduler 进程。手动启动后端时注意同理。

## 前端

```bash
cd frontend && npm run build   # vue-tsc typecheck + vite build (type errors block build)
cd frontend && npm run dev     # Vite dev server on 5173
```

`npm run build` 内置 typecheck，没有独立的 `typecheck`/`lint` 脚本。

路由 (history router, Tauri 模式用 memory router): `/`(Dashboard), `/scan`, `/scan/history`, `/scan/periods`, `/stock/:symbol`, `/backtest`, `/history`, `/history/:symbol`.

## CLI (通过 Zig API)

所有 CLI 命令自动侦测已运行的 sidecar (port 8000)；未运行时临时启动、用后清理。

```bash
./tauri-client.sh scan 100
./tauri-client.sh scan-period list week|month|quarter
./tauri-client.sh scan-period detail week 2026-04-27
./tauri-client.sh scan-period rebuild all|week|month|quarter
./tauri-client.sh stock 600519
./tauri-client.sh backtest examples/backtest-request.json

./tauri-client.sh sync stats
./tauri-client.sh sync backfill --years 10 --limit 50
./tauri-client.sh sync update --limit 200

./tauri-client.sh scheduler start [30]    # 启动后台调度器
./tauri-client.sh scheduler stop|status|once
./tauri-client.sh scheduler run [30]      # 前台运行 (launchd 用)
./tauri-client.sh scheduler install-autostart|remove-autostart|autostart-status  # macOS 自启动
```

## HTTP API

Zig sidecar 接口 (`http://127.0.0.1:8000`):

- `GET /api/health`
- `GET /api/scan?top_n=100`
- `POST /api/scan/run?top_n=100`
- `GET /api/scan/history`, `GET /api/scan/history/{date}`
- `GET /api/scan/periods?period=week|month|quarter`
- `GET /api/scan/periods/{period}/{date}`
- `POST /api/scan/periods/rebuild?period=week|month|quarter|all`
- `GET /api/stock/search?q=600519`
- `GET /api/stock/{symbol}/basic|profile|technical|valuation|industry|full`
- `GET /api/daily-k/{symbol}`
- `GET /api/factors`
- `POST /api/backtest`, `POST /api/backtest/tasks`
- `GET /api/backtest/tasks`, `GET /api/backtest/tasks/{task_id}`
- `POST /api/backtest/tasks/{task_id}/cancel`
- `GET /api/backtest/history`

## 回测因子

`momentum_20d`, `momentum_60d`, `momentum_120d`, `pe_percentile`, `price_percentile`, `volatility_20d`, `volume_change`, `rsi_14`, `ma_deviation_20`

## Zig 源码结构

`zig/src/` 模块化拆分: `main.zig` 为入口, `backtest.zig`/`backtest_*.zig` (回测引擎/因子/缓存), `duckdb.zig` (DB), `sync.zig` (数据同步), `http_helpers.zig`/`sql_text.zig` (工具), `eastmoney.zig`/`baidu.zig`/`tencent.zig` (数据源), `test_duckdb*.zig` (测试)。

## 验证

```bash
bash tests/test_zig_only_project.sh      # Zig 侧集成测试 (检查无 Python 残留 + 模块导入 + zig test)
zsh -n tauri-client.sh                   # shell syntax check (zsh only!)
zsh -n server.sh
cd frontend && npm run build             # typecheck + 构建
./tauri-client.sh ensure-sidecar          # sidecar 编译
```

`test_zig_only_project.sh` 验证项目已完全从 Python 迁移到 Zig (无 `.py` 文件、无 Python runtime 引用)。

## 网页部署

前端可通过 GitHub Pages 部署（静态文件），但 Zig 后端需另部署到服务器。

```bash
# 本地构建前端 (开发模式, 默认 / 基路径 + Vite proxy)
cd frontend && npm run build

# 网页部署构建 (设置后端地址和基路径)
VITE_API_BASE_URL=https://your-server.com npx vite build --base /vaporwave/
```

**环境变量**:
- `VITE_API_BASE_URL` — Zig 后端地址, dev 模式下留空走 Vite proxy, 部署时必填
- `--base /vaporwave/` — GitHub Pages 子路径, 需与 repo 名一致

**GitHub Actions**: push `main` 分支自动构建部署到 GitHub Pages (`.github/workflows/deploy.yml`)。在仓库 `Settings > Secrets and variables > Actions > Variables` 中设置 `VITE_API_BASE_URL`。

前端 `buildUrl` 在非 Tauri 模式下通过 `axios` + `VITE_API_BASE_URL` 访问后端 (`frontend/src/api/index.ts:438-445`)。后端已有 CORS header (`zig/src/http_helpers.zig:65`)。

## 相关文档

- `CLAUDE.md` — 与本文档内容相同
- `docs/backtest-system.md` — 回测系统架构
- `docs/backtest-optimization-plan.md` — 回测优化计划
- `docs/superpowers/` — 各能力模块文档

## 免责声明

本工具基于公开数据进行分析，仅供研究和学习参考，不构成投资建议。
