#!/usr/bin/env bash
# tail-logs.sh — stream TrackNotch os_log live (app must already be running)
# Logs also append to a timestamped file in .debug/logs/

LOG_DIR="/Users/manojachari/tracknotch/.debug/logs"
LOG_FILE="$LOG_DIR/tracknotch-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR"

PID=$(pgrep -x TrackNotch)
if [ -z "$PID" ]; then
  echo "[debug] TrackNotch is not running."
  exit 1
fi

echo "[debug] TrackNotch PID: $PID — tailing logs to $LOG_FILE"
echo "[debug] Ctrl+C stops the tail; the app keeps running."

log stream \
  --predicate 'subsystem == "com.tracknotch.app"' \
  --level debug \
  --style compact \
  2>&1 | tee "$LOG_FILE"
