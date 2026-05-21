#!/usr/bin/env bash
# start-debug.sh — launch TrackNotch debug build + tail logs to file
# Usage: ./start-debug.sh [--no-log]

APP="/Users/manojachari/tracknotch/TrackNotch/build/Build/Products/Debug/TrackNotch.app"
LOG_DIR="/Users/manojachari/tracknotch/.debug/logs"
LOG_FILE="$LOG_DIR/tracknotch-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$LOG_DIR"

# Kill any existing instance
if pgrep -x TrackNotch > /dev/null; then
  echo "[debug] Killing existing TrackNotch..."
  pkill -x TrackNotch
  sleep 1
fi

echo "[debug] Launching: $APP"
open -a "$APP"
sleep 2  # give app time to start

PID=$(pgrep -x TrackNotch)
if [ -z "$PID" ]; then
  echo "[debug] ERROR: TrackNotch did not start."
  exit 1
fi

echo "[debug] TrackNotch running as PID $PID"
echo "[debug] Streaming logs to: $LOG_FILE"
echo "[debug] Press Ctrl+C to stop log streaming (app keeps running)"

# Stream os_log from subsystem to file
log stream \
  --predicate 'subsystem == "com.tracknotch.app"' \
  --level debug \
  --style compact \
  2>&1 | tee "$LOG_FILE"
