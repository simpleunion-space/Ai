#!/bin/sh
set -eu
if [ "$#" -eq 0 ]; then set -- serve; fi
exec /usr/bin/tini -- python3 /usr/local/lib/llamacpp/runtime.py "$@"
