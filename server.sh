#!/usr/bin/env zsh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$SCRIPT_DIR/.server.pid"
BACKEND_PID=""
FRONTEND_PID=""

cleanup() {
    echo ""
    echo "正在关闭服务..."
    if [ -f "$PID_FILE" ]; then
        local pids
        pids=$(cat "$PID_FILE")
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                echo "  已关闭进程 $pid"
            fi
        done
        rm -f "$PID_FILE"
    fi
    # Fallback: kill by port
    local backend_pid
    backend_pid=$(lsof -tiTCP:8000 -sTCP:LISTEN 2>/dev/null || true)
    if [ -n "$backend_pid" ]; then
        kill $backend_pid 2>/dev/null || true
        echo "  已关闭后端端口 8000"
    fi
    local frontend_pid
    frontend_pid=$(lsof -tiTCP:5173 -sTCP:LISTEN 2>/dev/null || true)
    if [ -n "$frontend_pid" ]; then
        kill $frontend_pid 2>/dev/null || true
        echo "  已关闭前端端口 5173"
    fi
    echo "服务已关闭"
    exit 0
}

start() {
    # Check if already running
    if [ -f "$PID_FILE" ]; then
        local pids
        pids=$(cat "$PID_FILE")
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                echo "服务已在运行 (PID: $pids)"
                echo "运行 $0 stop 关闭服务"
                return 0
            fi
        done
        rm -f "$PID_FILE"
    fi

    trap cleanup INT TERM

    echo "========================================"
    echo "  VAPORWAVE QUANT - 启动服务"
    echo "========================================"

    # Release the background scheduler's DuckDB write lock before starting the dev backend.
    if [ -x "$SCRIPT_DIR/tauri-client.sh" ]; then
        echo "[0/2] 检查 DuckDB 开发写锁..."
        "$SCRIPT_DIR/tauri-client.sh" dev-unlock-db || true
    fi

    # Start backend
    echo "[1/2] 启动 Zig sidecar 后端 (port:8000)..."
    cd "$SCRIPT_DIR"
    "$SCRIPT_DIR/tauri-client.sh" serve 8000 &
    BACKEND_PID=$!
    echo "  后端 PID: $BACKEND_PID"

    # Wait for backend to be ready
    echo "  等待后端就绪..."
    for i in $(seq 1 30); do
        if curl --noproxy '*' -s http://127.0.0.1:8000/api/health >/dev/null 2>&1; then
            echo "  后端就绪 ✓"
            break
        fi
        sleep 0.5
    done

    # Start frontend
    echo "[2/2] 启动前端 (port:5173)..."
    cd "$SCRIPT_DIR/frontend"
    npx vite --host 127.0.0.1 &
    FRONTEND_PID=$!
    echo "  前端 PID: $FRONTEND_PID"

    # Save PIDs
    echo "$BACKEND_PID $FRONTEND_PID" > "$PID_FILE"

    echo ""
    echo "========================================"
    echo "  服务已启动"
    echo "  前端: http://127.0.0.1:5173"
    echo "  Zig 后端: http://127.0.0.1:8000"
    echo "========================================"
    echo "  按 Ctrl+C 关闭所有服务"
    echo "========================================"
    echo ""

    # Wait for both processes
    wait
}

stop() {
    echo "正在关闭服务..."
    if [ -f "$PID_FILE" ]; then
        local pids
        pids=$(cat "$PID_FILE")
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
                echo "  已关闭进程 $pid"
            fi
        done
        rm -f "$PID_FILE"
    fi
    local backend_pid
    backend_pid=$(lsof -tiTCP:8000 -sTCP:LISTEN 2>/dev/null || true)
    if [ -n "$backend_pid" ]; then
        kill $backend_pid 2>/dev/null || true
        echo "  已关闭后端端口 8000"
    fi
    local frontend_pid
    frontend_pid=$(lsof -tiTCP:5173 -sTCP:LISTEN 2>/dev/null || true)
    if [ -n "$frontend_pid" ]; then
        kill $frontend_pid 2>/dev/null || true
        echo "  已关闭前端端口 5173"
    fi
    echo "服务已关闭"
}

status() {
    local has_running=false
    if [ -f "$PID_FILE" ]; then
        local pids
        pids=$(cat "$PID_FILE")
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                echo "进程 $pid 运行中"
                has_running=true
            fi
        done
    fi
    local backend_pid
    backend_pid=$(lsof -tiTCP:8000 -sTCP:LISTEN 2>/dev/null || true)
    if [ -n "$backend_pid" ]; then
        echo "后端 (8000) 运行中 PID: $backend_pid"
        has_running=true
    fi
    local frontend_pid
    frontend_pid=$(lsof -tiTCP:5173 -sTCP:LISTEN 2>/dev/null || true)
    if [ -n "$frontend_pid" ]; then
        echo "前端 (5173) 运行中 PID: $frontend_pid"
        has_running=true
    fi
    if [ "$has_running" = false ]; then
        echo "服务未运行"
    fi
}

case "${1:-start}" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        stop
        sleep 1
        start
        ;;
    status)
        status
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status}"
        echo ""
        echo "  start   - 启动前后端服务 (默认)"
        echo "  stop    - 关闭所有服务"
        echo "  restart - 重启服务"
        echo "  status  - 查看服务状态"
        exit 1
        ;;
esac
