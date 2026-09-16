#!/bin/sh

set -eu

# Pure liveness check - deliberately does NOT require a model to be loaded.
# Until 2026-09-12 this also gated on a model-loaded marker file plus an
# `lms ps` identifier/context/parallel match (see git history) so Swarm
# wouldn't call the container "healthy" before it could actually serve
# inference - but that borrowed start_period (then 24h) as its only defense
# against Swarm's own restart_policy (condition: any, no max_attempts)
# killing the container mid-download, exactly like the already-fixed
# 2026-09-07 status=="idle" incident killed it mid-generation. Once
# start_period was standardized to 5m across every service, any real
# from-scratch download or model swap (both routed through this same
# entrypoint) would hit that same failure mode again, just on a new
# trigger. Model readiness is already tracked independently of Docker's
# health status - apply-model-profile.sh's wait_lmstudio_profile_ready()
# and apply.sh's check_lmstudio_model_inventory() both poll `lms ps --json`
# directly via docker exec, with their own multi-hour timeouts, and neither
# one ever looked at this healthcheck's exit code. Trade-off accepted: a
# healthy `docker service ls` now means "the process is up and answering",
# not "the configured model is ready" - that's only visible during an
# active deploy/model-apply/model-verify run, not by glancing at service
# status. In exchange, Swarm can no longer kill this container for still
# being mid-download, on a fresh install or an ordinary model swap alike.
api_port="${LMSTUDIO_PORT:-1234}"

curl --fail --silent --show-error "http://127.0.0.1:${api_port}/v1/models" >/dev/null
