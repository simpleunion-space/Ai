#!/bin/sh
set -eu
case "${1:-}" in
    '') exec python3 /usr/local/lib/llamacpp/runtime.py health ;;
    --ready|--verify-loaded) exec python3 /usr/local/lib/llamacpp/runtime.py ready ;;
    *) exit 2 ;;
esac
