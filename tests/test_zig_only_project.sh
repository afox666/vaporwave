#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

python_artifacts="$(
  find . \
    -path './.git' -prune -o \
    -path './.venv' -prune -o \
    -path './frontend/node_modules' -prune -o \
    -path './frontend/dist' -prune -o \
    -path './src-tauri/target' -prune -o \
    -path './zig/.zig-cache' -prune -o \
    -path './zig/zig-out' -prune -o \
    \( -name '*.py' -o -name 'pyproject.toml' -o -name 'uv.lock' -o -name '.python-version' \) -print
)"

if [[ -n "$python_artifacts" ]]; then
  printf '%s\n' "$python_artifacts" >&2
  fail "project Python artifacts remain"
fi

if rg -n "python|uv run|api\\.py|backtest\\.py|akshare_skill\\.py|sync_data\\.py|celery|FastAPI" \
  --glob '!frontend/node_modules/**' \
  --glob '!frontend/dist/**' \
  --glob '!src-tauri/target/**' \
  --glob '!zig/.zig-cache/**' \
  --glob '!zig/zig-out/**' \
  --glob '!tests/test_zig_only_project.sh' \
  . >/tmp/akshare-python-refs.txt; then
  cat /tmp/akshare-python-refs.txt >&2
  fail "Python runtime references remain"
fi

script="$(< tauri-client.sh)"

[[ "$script" == *"scan)"* ]] || fail "tauri-client.sh lacks scan command"
[[ "$script" == *"stock)"* ]] || fail "tauri-client.sh lacks stock command"
[[ "$script" == *"backtest)"* ]] || fail "tauri-client.sh lacks backtest command"
[[ "$script" == *"/api/scan?top_n="* ]] || fail "scan CLI does not call Zig scan API"
[[ "$script" == *"/api/stock/\${symbol}/full"* ]] || fail "stock CLI does not call Zig stock API"
[[ "$script" == *"/api/backtest"* ]] || fail "backtest CLI does not call Zig backtest API"

printf 'Zig-only project shape verified\n'
