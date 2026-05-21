#!/usr/bin/env bash
# logger-daemon.sh — persistent background log collector for TrackNotch
# Writes all TNLog output to a rolling daily log file.
# Survives terminal close. Re-attaches to app restarts automatically.

LOG_DIR="/Users/manojachari/tracknotch/.debug/logs"
PIDFILE="/Users/manojachari/tracknotch/.debug/logger.pid"

mkdir -p "$LOG_DIR"

# If already running, exit silently
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "[logger] Already running as PID $(cat $PIDFILE)"
  exit 0
fi

LOG_FILE="$LOG_DIR/tracknotch-$(date +%Y%m%d).log"

echo "[logger] Starting persistent logger → $LOG_FILE"

# Run in background, disown so it survives terminal close
(
  while true; do
    # Roll to a new file at midnight
    CURRENT_LOG="$LOG_DIR/tracknotch-$(date +%Y%m%d).log"
    log stream \
      --predicate 'subsystem == "com.tracknotch.app"' \
      --level debug \
      --style compact \
      >> "$CURRENT_LOG" 2>&1
    # If log stream exits (rare), wait a moment and restart
    sleep 5
  done
) &

DAEMON_PID=$!
echo $DAEMON_PID > "$PIDFILE"
disown $DAEMON_PID

echo "[logger] Daemon PID $DAEMON_PID — logging to $LOG_DIR/tracknotch-YYYYMMDD.log"
echo "[logger] Run stop-logger.sh to stop."
