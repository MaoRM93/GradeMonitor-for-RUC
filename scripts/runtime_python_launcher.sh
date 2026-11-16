#!/bin/sh
# App 内嵌 Python 的启动器：不读取用户环境，始终从包内资源定位标准库。
set -eu
RUNTIME_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
export PYTHONHOME="$RUNTIME_ROOT"
exec "$RUNTIME_ROOT/bin/python3.11" "$@"
