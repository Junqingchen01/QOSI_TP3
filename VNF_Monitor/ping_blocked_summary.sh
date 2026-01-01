#!/bin/sh

LOG="/var/log/ping_blocked_live.log"
OUT="/var/log/ping_blocked_report_$(date +'%Y-%m-%d_%H-%M-%S').txt"

if [ ! -f "$LOG" ]; then
  echo "[ERRO] Não existe o ficheiro: $LOG"
  exit 1
fi

# Contar eventos
TOTAL=$(grep -c "PING_BLOCKED" "$LOG" 2>/dev/null)

# Obter primeira e última linha do evento
FIRST_LINE=$(grep "PING_BLOCKED" "$LOG" | head -n 1)
LAST_LINE=$(grep "PING_BLOCKED" "$LOG" | tail -n 1)

# Extrair timestamp (assume formato ISO no início da linha se existir; senão usa a linha toda)
FIRST_TS=$(echo "$FIRST_LINE" | awk '{print $1" "$2}')
LAST_TS=$(echo "$LAST_LINE" | awk '{print $1" "$2}')

# Se não houver eventos
if [ "$TOTAL" -eq 0 ]; then
  REPORT="=============================
RELATÓRIO PING_BLOCKED
=============================
Total de bloqueios: 0
Janela temporal: (sem eventos)
Ficheiro analisado: $LOG
Gerado em: $(date +'%Y-%m-%d %H:%M:%S')
============================="
else
  REPORT="=============================
RELATÓRIO PING_BLOCKED
=============================
Total de bloqueios: $TOTAL
Janela temporal: $FIRST_TS  ->  $LAST_TS
Ficheiro analisado: $LOG
Gerado em: $(date +'%Y-%m-%d %H:%M:%S')
============================="
fi

# Mostrar no ecrã
echo "$REPORT"

# Guardar em ficheiro
echo "$REPORT" > "$OUT"

echo "[OK] Relatório guardado em: $OUT"
