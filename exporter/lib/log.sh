#!/usr/bin/env bash
# Simple logger: INFO/DEBUG with timestamps
LOG_LEVEL="${LOG_LEVEL:-info}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

_log_level_num() {
  case "$LOG_LEVEL" in
    debug) echo 10 ;;
    info)  echo 20 ;;
    *)     echo 20 ;;
  esac
}

_should_log() {
  local level="$1"
  local cur=$(_log_level_num)
  local req
  case "$level" in
    DEBUG) req=10 ;;
    INFO)  req=20 ;;
    *)     req=20 ;;
  esac
  [[ $cur -le $req ]]
}

log_info()  { _should_log INFO  && echo "$(ts) INFO  $*"; }
log_debug() { _should_log DEBUG && echo "$(ts) DEBUG $*"; }
log_err()   { echo "$(ts) ERROR $*" >&2; }
