#!/usr/bin/env zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PID_FILE="$SCRIPT_DIR/.tauri-client.pid"
SCHEDULER_PID_FILE="$SCRIPT_DIR/.scheduler.pid"
SCHEDULER_LOG_FILE="$SCRIPT_DIR/.scheduler.log"
SCHEDULER_STATE_FILE="$SCRIPT_DIR/.scheduler-state"
LAUNCH_AGENT_ID="com.afox.akshare.scheduler"
LAUNCH_AGENT_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_AGENT_ID.plist"
CLI_SIDECAR_PID=""
CLI_SIDECAR_PORT=""

APP_BUNDLE="$SCRIPT_DIR/src-tauri/target/release/bundle/macos/vaporwave.app"
APP_EXEC="$APP_BUNDLE/Contents/MacOS/app"
DMG_PATH="$SCRIPT_DIR/src-tauri/target/release/bundle/dmg/vaporwave_0.1.0_aarch64.dmg"

SIDECAR_SRC="$SCRIPT_DIR/src-tauri/sidecars/vaporwave-sidecar-aarch64-apple-darwin"
SIDECAR_EXEC="$APP_BUNDLE/Contents/MacOS/vaporwave-sidecar"
DB_PATH="$SCRIPT_DIR/market_data.db"

log() {
    print -r -- "$*"
}

die() {
    log "错误: $*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

app_pids() {
    pgrep -f "$APP_EXEC" 2>/dev/null || true
}

sidecar_pids() {
    pgrep -f "$SIDECAR_EXEC" 2>/dev/null || true
}

saved_pids() {
    if [[ -f "$PID_FILE" ]]; then
        tr ' ' '\n' < "$PID_FILE" | awk 'NF && !seen[$0]++'
    fi
}

scheduler_pids() {
    pgrep -f "$SIDECAR_SRC.*--db $DB_PATH.*--scheduler" 2>/dev/null || true
}

saved_scheduler_pids() {
    if [[ -f "$SCHEDULER_PID_FILE" ]]; then
        tr ' ' '\n' < "$SCHEDULER_PID_FILE" | awk 'NF && !seen[$0]++'
    fi
}

is_running() {
    [[ -n "$(app_pids)" || -n "$(sidecar_pids)" ]]
}

terminate_pids() {
    local pids=("$@")
    if (( ${#pids[@]} == 0 )); then
        return 0
    fi

    for pid in "${pids[@]}"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            log "  已发送停止信号: $pid"
        fi
    done

    for _ in {1..25}; do
        local alive=false
        for pid in "${pids[@]}"; do
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                alive=true
                break
            fi
        done
        [[ "$alive" == false ]] && return 0
        sleep 0.2
    done

    for pid in "${pids[@]}"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
            log "  已强制关闭: $pid"
        fi
    done
}

find_duckdb_lib_dir() {
    local dirs=(
        /opt/homebrew/lib
        /opt/homebrew/opt/duckdb/lib
        /usr/local/lib
        /usr/local/opt/duckdb/lib
    )

    for dir in "${dirs[@]}"; do
        if [[ -f "$dir/libduckdb.dylib" ]]; then
            print -r -- "$dir"
            return 0
        fi
    done

    return 1
}

run_sidecar_command() {
    ensure_sidecar_exists

    local duckdb_lib_dir
    duckdb_lib_dir="$(find_duckdb_lib_dir)" || die "找不到 libduckdb.dylib，请先安装 duckdb"

    DYLD_LIBRARY_PATH="$duckdb_lib_dir:${DYLD_LIBRARY_PATH:-}" \
        "$SIDECAR_SRC" --db "$DB_PATH" "$@"
}

choose_cli_port() {
    local port
    for port in {8790..8819}; do
        if ! lsof -tiTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
            print -r -- "$port"
            return 0
        fi
    done
    die "找不到可用的临时 CLI 端口"
}

running_cli_base_url() {
    if command -v curl >/dev/null 2>&1; then
        if curl --noproxy '*' -fsS "http://127.0.0.1:8000/api/health" >/dev/null 2>&1; then
            print -r -- "http://127.0.0.1:8000"
            return 0
        fi
    fi
    return 1
}

cleanup_cli_sidecar() {
    if [[ -n "${CLI_SIDECAR_PID:-}" ]] && kill -0 "$CLI_SIDECAR_PID" 2>/dev/null; then
        kill "$CLI_SIDECAR_PID" 2>/dev/null || true
        wait "$CLI_SIDECAR_PID" 2>/dev/null || true
    fi
    CLI_SIDECAR_PID=""
    CLI_SIDECAR_PORT=""
}

start_cli_sidecar() {
    ensure_sidecar_exists

    local duckdb_lib_dir
    duckdb_lib_dir="$(find_duckdb_lib_dir)" || die "找不到 libduckdb.dylib，请先安装 duckdb"

    CLI_SIDECAR_PORT="$(choose_cli_port)"
    log "启动临时 Zig sidecar: http://127.0.0.1:$CLI_SIDECAR_PORT" >&2
    (
        cd "$SCRIPT_DIR"
        env DYLD_LIBRARY_PATH="$duckdb_lib_dir:${DYLD_LIBRARY_PATH:-}" \
            "$SIDECAR_SRC" --db "$DB_PATH" --port "$CLI_SIDECAR_PORT"
    ) >/tmp/akshare-sidecar-cli.log 2>&1 &
    CLI_SIDECAR_PID=$!

    local i
    for i in {1..40}; do
        if curl --noproxy '*' -fsS "http://127.0.0.1:$CLI_SIDECAR_PORT/api/health" >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$CLI_SIDECAR_PID" 2>/dev/null; then
            cat /tmp/akshare-sidecar-cli.log >&2 2>/dev/null || true
            die "临时 Zig sidecar 启动失败"
        fi
        sleep 0.25
    done

    cat /tmp/akshare-sidecar-cli.log >&2 2>/dev/null || true
    cleanup_cli_sidecar
    die "临时 Zig sidecar 启动超时"
}

cli_request() {
    local method="$1"
    local api_path="$2"
    local body_file="${3:-}"
    local base_url

    require_cmd curl
    if ! base_url="$(running_cli_base_url)"; then
        start_cli_sidecar
        trap cleanup_cli_sidecar EXIT INT TERM
        base_url="http://127.0.0.1:$CLI_SIDECAR_PORT"
    fi

    if [[ "$method" == "POST" ]]; then
        if [[ -n "$body_file" ]]; then
            [[ -f "$body_file" ]] || die "POST 请求需要可读取的 JSON 文件"
            curl --noproxy '*' -fsS \
                -H "Content-Type: application/json" \
                --data-binary "@$body_file" \
                "$base_url$api_path"
        else
            curl --noproxy '*' -fsS \
                -X POST \
                -H "Content-Type: application/json" \
                "$base_url$api_path"
        fi
    else
        curl --noproxy '*' -fsS "$base_url$api_path"
    fi
    printf '\n'
}

cli_scan() {
    local top_n="${1:-100}"
    cli_request GET "/api/scan?top_n=${top_n}"
}

cli_scan_period() {
    local action="${1:-list}"
    local period="${2:-week}"
    local period_start="${3:-}"

    case "$action" in
        list)
            cli_request GET "/api/scan/periods?period=${period}"
            ;;
        detail)
            [[ -n "$period_start" ]] || die "用法: ./tauri-client.sh scan-period detail <week|month|quarter> <YYYY-MM-DD>"
            cli_request GET "/api/scan/periods/${period}/${period_start}"
            ;;
        rebuild)
            cli_request POST "/api/scan/periods/rebuild?period=${period}"
            ;;
        *)
            die "用法: ./tauri-client.sh scan-period {list|detail|rebuild} [week|month|quarter|all] [YYYY-MM-DD]"
            ;;
    esac
}

cli_stock() {
    local symbol="${1:-}"
    [[ -n "$symbol" ]] || die "用法: ./tauri-client.sh stock <股票代码>"
    cli_request GET "/api/stock/${symbol}/full"
}

cli_backtest() {
    local request_file="${1:-}"
    [[ -n "$request_file" ]] || die "用法: ./tauri-client.sh backtest <request-json-file>"
    cli_request POST "/api/backtest" "$request_file"
}

serve_backend() {
    local port="${1:-8000}"
    ensure_sidecar_exists

    local duckdb_lib_dir
    duckdb_lib_dir="$(find_duckdb_lib_dir)" || die "找不到 libduckdb.dylib，请先安装 duckdb"

    log "启动 Zig sidecar HTTP 服务: http://127.0.0.1:$port"
    export DYLD_LIBRARY_PATH="$duckdb_lib_dir:${DYLD_LIBRARY_PATH:-}"
    exec "$SIDECAR_SRC" --db "$DB_PATH" --port "$port"
}

sync_bundled_sidecar_if_needed() {
    if [[ -x "$SIDECAR_SRC" && -d "$APP_BUNDLE" ]]; then
        if [[ ! -x "$SIDECAR_EXEC" || "$SIDECAR_SRC" -nt "$SIDECAR_EXEC" ]]; then
            cp "$SIDECAR_SRC" "$SIDECAR_EXEC"
            chmod +x "$SIDECAR_EXEC"
            log "  已同步 App 内 sidecar: $SIDECAR_EXEC"
            resign_app_bundle_if_needed
        fi
    fi
}

resign_app_bundle_if_needed() {
    [[ "$OSTYPE" == darwin* ]] || return 0
    [[ -d "$APP_BUNDLE" ]] || return 0

    require_cmd codesign
    if codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
        return 0
    fi

    log "  App 签名已失效，正在重新签名..."
    codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
    if ! codesign --verify --deep --strict "$APP_BUNDLE" >/dev/null 2>&1; then
        die "App 重新签名失败"
    fi
    log "  App 已重新签名"
}

build_sidecar() {
    require_cmd zig

    local duckdb_lib_dir
    duckdb_lib_dir="$(find_duckdb_lib_dir)" || die "找不到 libduckdb.dylib，请先安装 duckdb"

    log "[1/2] 编译 Zig sidecar..."
    (
        cd "$SCRIPT_DIR/zig"
        zig build-exe src/main.zig \
            -target aarch64-macos \
            -O ReleaseFast \
            -femit-bin=main \
            -L"$duckdb_lib_dir" \
            -lduckdb \
            -lc
    )

    cp "$SCRIPT_DIR/zig/main" "$SIDECAR_SRC"
    chmod +x "$SIDECAR_SRC"
    log "  sidecar 已更新: $SIDECAR_SRC"
    sync_bundled_sidecar_if_needed
}

build_app() {
    require_cmd npm
    require_cmd cargo

    build_sidecar

    log "[2/2] 构建 Tauri release 应用..."
    (
        cd "$SCRIPT_DIR/src-tauri"
        cargo tauri build
    )

    log ""
    log "构建完成:"
    log "  App: $APP_BUNDLE"
    log "  DMG: $DMG_PATH"
}

ensure_app_exists() {
    if [[ ! -x "$APP_EXEC" ]]; then
        log "未找到已构建的 Tauri 应用，开始构建..."
        build_app
    fi

    resign_app_bundle_if_needed
}

ensure_sidecar_exists() {
    if [[ ! -x "$SIDECAR_SRC" ]]; then
        log "未找到 Zig sidecar，开始编译..."
        build_sidecar
        return 0
    fi

    local src
    for src in "$SCRIPT_DIR"/zig/src/*.zig; do
        if [[ "$src" -nt "$SIDECAR_SRC" ]]; then
            log "Zig sidecar 源码有更新，开始编译..."
            build_sidecar
            return 0
        fi
    done
    if [[ "$SCRIPT_DIR/zig/build.zig" -nt "$SIDECAR_SRC" ]]; then
        log "Zig 构建文件有更新，开始编译..."
        build_sidecar
    fi
    sync_bundled_sidecar_if_needed
}

health_for_sidecar() {
    local pid="$1"
    local cmd port
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"

    if [[ "$cmd" != *"--port "* ]]; then
        log "  sidecar $pid: 未找到端口参数"
        return 0
    fi

    port="${cmd##*--port }"
    port="${port%% *}"

    if command -v curl >/dev/null 2>&1; then
        if curl --noproxy '*' -fsS "http://127.0.0.1:$port/api/health" >/dev/null 2>&1; then
            log "  sidecar $pid: http://127.0.0.1:$port OK"
        else
            log "  sidecar $pid: http://127.0.0.1:$port 无响应"
        fi
    else
        log "  sidecar $pid: http://127.0.0.1:$port"
    fi
}

status_app() {
    local app=($(app_pids))
    local sidecars=($(sidecar_pids))

    if (( ${#app[@]} == 0 && ${#sidecars[@]} == 0 )); then
        log "Tauri 客户端未运行"
        return 0
    fi

    if (( ${#app[@]} > 0 )); then
        log "Tauri 客户端运行中:"
        for pid in "${app[@]}"; do
            log "  app PID: $pid"
        done
    else
        log "Tauri 主进程未运行"
    fi

    if (( ${#sidecars[@]} > 0 )); then
        log "Sidecar 进程:"
        for pid in "${sidecars[@]}"; do
            health_for_sidecar "$pid"
        done
    else
        log "Sidecar 未运行"
    fi
}

start_app() {
    if [[ -n "$(app_pids)" ]]; then
        log "Tauri 客户端已在运行"
        status_app
        return 0
    fi

    local orphan_sidecars=($(sidecar_pids))
    if (( ${#orphan_sidecars[@]} > 0 )); then
        log "发现残留 sidecar，先清理..."
        terminate_pids "${orphan_sidecars[@]}"
    fi

    ensure_app_exists
    ensure_sidecar_exists

    log "启动 Tauri 客户端..."
    open "$APP_BUNDLE"

    for _ in {1..40}; do
        local app=($(app_pids))
        if (( ${#app[@]} > 0 )); then
            sleep 1
            local all_pids=($(app_pids) $(sidecar_pids))
            print -r -- "${all_pids[*]}" > "$PID_FILE"
            log "启动完成"
            status_app
            return 0
        fi
        sleep 0.5
    done

    die "启动超时，请检查 macOS 是否拦截应用或查看系统日志"
}

stop_app() {
    local pids=($(saved_pids) $(app_pids) $(sidecar_pids))

    if (( ${#pids[@]} == 0 )); then
        rm -f "$PID_FILE"
        log "Tauri 客户端未运行"
        return 0
    fi

    log "正在关闭 Tauri 客户端..."
    terminate_pids "${pids[@]}"
    rm -f "$PID_FILE"
    log "已关闭"
}

restart_app() {
    stop_app
    sleep 1
    start_app
}

toggle_app() {
    if is_running; then
        stop_app
    else
        start_app
    fi
}

sync_data() {
    local cmd="${1:-stats}"
    shift || true

    run_sidecar_command --sync "$cmd" "$@"
}

scheduler_run() {
    local interval="${1:-30}"
    run_sidecar_command --scheduler run --interval-seconds "$interval"
}

scheduler_once() {
    run_sidecar_command --scheduler once
}

scheduler_status() {
    local pids=($(scheduler_pids))
    if (( ${#pids[@]} > 0 )); then
        log "调度器进程:"
        for pid in "${pids[@]}"; do
            log "  scheduler PID: $pid"
        done
    else
        log "调度器未运行"
    fi

    if [[ -f "$SCHEDULER_LOG_FILE" ]]; then
        log "调度器日志: $SCHEDULER_LOG_FILE"
    fi

    if [[ -f "$SCHEDULER_STATE_FILE" ]]; then
        log "调度器状态快照: $SCHEDULER_STATE_FILE"
        cat "$SCHEDULER_STATE_FILE"
    elif [[ -f "$SCHEDULER_LOG_FILE" ]]; then
        log "最近日志:"
        tail -n 20 "$SCHEDULER_LOG_FILE"
    fi
}

write_scheduler_stopped_state() {
    print -r -- "updated_at=$(date '+%Y-%m-%d %H:%M:%S')
status=stopped
interval_seconds=
jobs=
job_name=
scheduled_for=
message=
" > "$SCHEDULER_STATE_FILE"
}

scheduler_start() {
    local interval="${1:-30}"
    local running=($(scheduler_pids))
    if (( ${#running[@]} > 0 )); then
        log "调度器已在运行"
        scheduler_status
        return 0
    fi

    ensure_sidecar_exists

    local duckdb_lib_dir
    duckdb_lib_dir="$(find_duckdb_lib_dir)" || die "找不到 libduckdb.dylib，请先安装 duckdb"

    log "启动调度器..."
    (
        cd "$SCRIPT_DIR"
        env DYLD_LIBRARY_PATH="$duckdb_lib_dir:${DYLD_LIBRARY_PATH:-}" \
            "$SIDECAR_SRC" --db "$DB_PATH" --scheduler daemonize --interval-seconds "$interval" \
            >> "$SCHEDULER_LOG_FILE" 2>&1
    )

    sleep 1
    local pid
    pid="$(scheduler_pids | head -n 1)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        print -r -- "$pid" > "$SCHEDULER_PID_FILE"
        log "调度器已启动: PID $pid"
        return 0
    fi

    rm -f "$SCHEDULER_PID_FILE"
    die "调度器启动失败，请查看 $SCHEDULER_LOG_FILE"
}

scheduler_stop() {
    local pids=($(saved_scheduler_pids) $(scheduler_pids))
    if (( ${#pids[@]} == 0 )); then
        rm -f "$SCHEDULER_PID_FILE"
        write_scheduler_stopped_state
        log "调度器未运行"
        return 0
    fi

    log "正在关闭调度器..."
    terminate_pids "${pids[@]}"
    rm -f "$SCHEDULER_PID_FILE"
    write_scheduler_stopped_state
    log "调度器已关闭"
}

dev_unlock_db() {
    local pids=($(scheduler_pids))
    if (( ${#pids[@]} == 0 )); then
        rm -f "$SCHEDULER_PID_FILE"
        write_scheduler_stopped_state
        log "DuckDB 开发锁检查: scheduler 未运行"
        return 0
    fi

    log "检测到 scheduler 可能持有 DuckDB 写锁，先停止..."
    scheduler_stop
}

scheduler_install_autostart() {
    [[ "$OSTYPE" == darwin* ]] || die "自动启动安装当前仅支持 macOS"
    mkdir -p "$HOME/Library/LaunchAgents"

    cat > "$LAUNCH_AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LAUNCH_AGENT_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>cd '$SCRIPT_DIR' &amp;&amp; '$SCRIPT_DIR/tauri-client.sh' scheduler run</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>WorkingDirectory</key>
  <string>$SCRIPT_DIR</string>
  <key>StandardOutPath</key>
  <string>$SCHEDULER_LOG_FILE</string>
  <key>StandardErrorPath</key>
  <string>$SCHEDULER_LOG_FILE</string>
</dict>
</plist>
EOF

    launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT_PLIST" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PLIST"
    launchctl enable "gui/$(id -u)/$LAUNCH_AGENT_ID" >/dev/null 2>&1 || true
    launchctl kickstart -k "gui/$(id -u)/$LAUNCH_AGENT_ID" >/dev/null 2>&1 || true

    log "已安装自动启动: $LAUNCH_AGENT_PLIST"
}

scheduler_remove_autostart() {
    [[ "$OSTYPE" == darwin* ]] || die "自动启动移除当前仅支持 macOS"
    launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT_PLIST" >/dev/null 2>&1 || true
    rm -f "$LAUNCH_AGENT_PLIST"
    log "已移除自动启动"
}

scheduler_autostart_status() {
    [[ "$OSTYPE" == darwin* ]] || die "自动启动状态当前仅支持 macOS"
    if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
        log "自动启动配置存在: $LAUNCH_AGENT_PLIST"
    else
        log "自动启动配置不存在"
    fi

    if launchctl print "gui/$(id -u)/$LAUNCH_AGENT_ID" >/dev/null 2>&1; then
        log "launchd 已加载 $LAUNCH_AGENT_ID"
    else
        log "launchd 未加载 $LAUNCH_AGENT_ID"
    fi
}

usage() {
    cat <<EOF
用法:
  ./tauri-client.sh              # 一键切换：未运行则启动，运行中则关闭
  ./tauri-client.sh start        # 启动客户端
  ./tauri-client.sh stop         # 停止客户端和残留 sidecar
  ./tauri-client.sh restart      # 重启客户端
  ./tauri-client.sh status       # 查看运行状态
  ./tauri-client.sh ensure-sidecar # 编译/同步最新 Zig sidecar
  ./tauri-client.sh serve [8000] # 前台启动 Zig HTTP 后端
  ./tauri-client.sh dev-unlock-db  # 开发模式启动 Zig 后端前释放 scheduler 写锁
  ./tauri-client.sh build        # 重新构建 release 应用
  ./tauri-client.sh rebuild      # 停止、构建、再启动
  ./tauri-client.sh sync stats   # 使用 Zig 后端执行数据同步/统计命令
  ./tauri-client.sh scan [100]   # 使用 Zig API 扫描市场，输出 JSON
  ./tauri-client.sh scan-period list week
  ./tauri-client.sh scan-period detail week 2026-04-27
  ./tauri-client.sh scan-period rebuild all
  ./tauri-client.sh stock 600519 # 使用 Zig API 输出单股完整分析 JSON
  ./tauri-client.sh backtest request.json # 使用 Zig API 运行同步回测
  ./tauri-client.sh scheduler start [30]
  ./tauri-client.sh scheduler stop
  ./tauri-client.sh scheduler status
  ./tauri-client.sh scheduler once
  ./tauri-client.sh scheduler run [30]            # 前台运行，适合 launchd
  ./tauri-client.sh scheduler install-autostart   # macOS 自动启动
  ./tauri-client.sh scheduler remove-autostart
  ./tauri-client.sh scheduler autostart-status

构建产物:
  App: $APP_BUNDLE
  DMG: $DMG_PATH

同步示例:
  ./tauri-client.sh sync stats
  ./tauri-client.sh sync backfill --years 10 --limit 50
  ./tauri-client.sh sync update --limit 200
  ./tauri-client.sh sync update-since --since 2026-06-01 --limit 200

CLI 示例:
  ./tauri-client.sh scan 50
  ./tauri-client.sh scan-period list week
  ./tauri-client.sh scan-period detail week 2026-04-27
  ./tauri-client.sh scan-period rebuild all
  ./tauri-client.sh stock 600519
  ./tauri-client.sh backtest examples/backtest-request.json

调度器示例:
  ./tauri-client.sh scheduler start
  ./tauri-client.sh scheduler once
  ./tauri-client.sh scheduler install-autostart
EOF
}

case "${1:-toggle}" in
    start|run)
        start_app
        ;;
    stop)
        stop_app
        ;;
    restart)
        restart_app
        ;;
    status)
        status_app
        ;;
    ensure-sidecar)
        ensure_sidecar_exists
        ;;
    serve)
        shift || true
        serve_backend "${1:-8000}"
        ;;
    dev-unlock-db)
        dev_unlock_db
        ;;
    build)
        build_app
        ;;
    rebuild)
        stop_app
        build_app
        start_app
        ;;
    sync)
        shift
        sync_data "$@"
        ;;
    scan)
        shift || true
        cli_scan "${1:-100}"
        ;;
    scan-period)
        shift || true
        cli_scan_period "${1:-list}" "${2:-week}" "${3:-}"
        ;;
    stock)
        shift || true
        cli_stock "${1:-}"
        ;;
    backtest)
        shift || true
        cli_backtest "${1:-}"
        ;;
    scheduler)
        shift || true
        case "${1:-status}" in
            start)
                shift || true
                scheduler_start "${1:-30}"
                ;;
            stop)
                scheduler_stop
                ;;
            status)
                scheduler_status
                ;;
            once)
                scheduler_once
                ;;
            run)
                shift || true
                scheduler_run "${1:-30}"
                ;;
            install-autostart)
                scheduler_install_autostart
                ;;
            remove-autostart)
                scheduler_remove_autostart
                ;;
            autostart-status)
                scheduler_autostart_status
                ;;
            *)
                usage
                exit 1
                ;;
        esac
        ;;
    toggle)
        toggle_app
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
