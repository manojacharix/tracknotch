#!/usr/bin/env bash
# stop-logger.sh — stop the persistent background logger

PIDFILE="/Users/manojachari/tracknotch/.debug/logger.pid"

if [ ! -f "$PIDFILE" ]; then
  echo "[logger] Not running (no pidfile found)."
  exit 0
fi

PID=$(cat "$PIDFILE")
if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  rm -f "$PIDFILE"
  echo "[logger] Stopped PID $PID."
else
  echo "[logger] PID $PID not found — already stopped."
  rm -f "$PIDFILE"
fi
