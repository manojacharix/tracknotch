#!/usr/bin/env bash
# check-logger.sh — show logger status and tail recent log entries

PIDFILE="/Users/manojachari/tracknotch/.debug/logger.pid"
LOG_DIR="/Users/manojachari/tracknotch/.debug/logs"
TODAY_LOG="$LOG_DIR/tracknotch-$(date +%Y%m%d).log"

echo "=== Logger daemon ==="
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "  Status : RUNNING (PID $(cat $PIDFILE))"
else
  echo "  Status : STOPPED"
fi

echo ""
echo "=== TrackNotch app ==="
PID=$(pgrep -x TrackNotch)
if [ -n "$PID" ]; then
  echo "  Status : RUNNING (PID $PID)"
else
  echo "  Status : NOT RUNNING"
fi

echo ""
echo "=== Today's log: $TODAY_LOG ==="
if [ -f "$TODAY_LOG" ]; then
  LINE_COUNT=$(wc -l < "$TODAY_LOG")
  SIZE=$(du -sh "$TODAY_LOG" | cut -f1)
  echo "  Lines  : $LINE_COUNT"
  echo "  Size   : $SIZE"
  echo ""
  echo "--- Last 20 lines ---"
  tail -20 "$TODAY_LOG"
else
  echo "  No log file yet for today."
fi

echo ""
echo "=== Fix Verification ==="
if [ -f "$TODAY_LOG" ]; then
  COUNT2=$(grep -c "\[UI\] Settings button" "$TODAY_LOG" 2>/dev/null || echo 0)
  echo "  Bug2 (settings button): triggered $COUNT2 time(s) today"

  COUNT1=$(grep -c "Wake reset:" "$TODAY_LOG" 2>/dev/null || echo 0)
  echo "  Bug1 (wake pill reset): triggered $COUNT1 time(s) today"

  COUNT3=$(grep -c "Weekly scan:" "$TODAY_LOG" 2>/dev/null || echo 0)
  if [ "$COUNT3" -gt 0 ]; then
    LAST3=$(grep "Weekly scan:" "$TODAY_LOG" | tail -1)
    echo "  Bug3 (weekly tokens):   seen $COUNT3 time(s) — last: $LAST3"
  else
    echo "  Bug3 (weekly tokens):   no scan result yet (first poll ~9s after launch)"
  fi
else
  echo "  No log file yet — start logger first: bash logger-daemon.sh"
fi
