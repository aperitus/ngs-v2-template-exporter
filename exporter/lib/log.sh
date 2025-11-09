#!/usr/bin/env bash
LOG_LEVEL="${LOG_LEVEL:-info}"
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
_lvl() { case "${LOG_LEVEL}" in debug) echo 10;; info) echo 20;; *) echo 20;; esac; }
_ok()  { local need=20; [[ "${1}" == "DEBUG" ]] && need=10; [[ $(_lvl) -le $need ]]; }
log_info()  { _ok INFO  && echo "$(ts) INFO  $*"; }
log_debug() { _ok DEBUG && echo "$(ts) DEBUG $*"; }
log_err()   { echo "$(ts) ERROR $*" >&2; }
