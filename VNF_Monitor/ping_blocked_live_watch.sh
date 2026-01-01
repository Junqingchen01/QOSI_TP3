#!/bin/sh

LOG_SRC="/var/log/ping_blocked_live.log"

# Criar ficheiro de sessão com timestamp
SESSION_LOG="/var/log/ping_blocked_$(date +'%Y-%m-%d_%H-%M-%S').log"

echo "===================================================="
echo "  🔴 MONITOR DE BLOQUEIOS ICMP (PING)"
echo "===================================================="
echo "📄 Ficheiro LIVE:    $LOG_SRC"
echo "📁 Ficheiro SESSÃO:  $SESSION_LOG"
echo "🎧 A escutar eventos em tempo real..."
echo "===================================================="

# Garantir que o ficheiro LIVE existe (foi o que te faltou)
if [ ! -f "$LOG_SRC" ]; then
  touch "$LOG_SRC"
  chmod 644 "$LOG_SRC" 2>/dev/null
fi

# Garantir ficheiro de sessão
touch "$SESSION_LOG"
chmod 644 "$SESSION_LOG" 2>/dev/null

# Se o ficheiro LIVE for apagado enquanto estás a ver, recria-o
watch_live_file() {
  while true; do
    [ -f "$LOG_SRC" ] || { touch "$LOG_SRC"; chmod 644 "$LOG_SRC" 2>/dev/null; }
    sleep 1
  done
}

watch_live_file >/dev/null 2>&1 &
WATCH_PID=$!

cleanup() {
  kill "$WATCH_PID" 2>/dev/null
  exit 0
}
trap cleanup INT TERM

# Ler em tempo real
tail -f "$LOG_SRC" | while IFS= read -r line; do
  TS="$(date +'%Y-%m-%d %H:%M:%S')"

  # Guardar no ficheiro de sessão
  echo "[$TS] $line" >> "$SESSION_LOG"

  # Mostrar no terminal com cores
  if echo "$line" | grep -q "PING_BLOCKED"; then
    printf "\033[31m[%s] ⛔ %s\033[0m\n" "$TS" "$line"
  else
    printf "\033[32m[%s] ✅ %s\033[0m\n" "$TS" "$line"
  fi
done
