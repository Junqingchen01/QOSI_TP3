#!/bin/sh
set -eu

# =========================
# CONFIG
# =========================
DUR="${DUR:-60}"                 # segundos
IFACE="${IFACE:-br0}"
HOST_SRC="${HOST_SRC:-10.0.0.10}"
SERVER_DST="${SERVER_DST:-10.0.0.20}"

PORT_VOIP="${PORT_VOIP:-5201}"   # UDP destino VoIP
PORT_VIDEO="${PORT_VIDEO:-5202}" # UDP destino Vídeo
PORT_BE="${PORT_BE:-5203}"       # TCP destino BE

# DSCP/TOS esperados (como tens observado no tcpdump)
TOS_EF="0xb8"
TOS_AF="0x88"
TOS_BE="0x0"

LOGDIR="${LOGDIR:-/var/log}"
TS="$(date '+%Y-%m-%d_%H-%M-%S')"
LOGFILE="${LOGDIR}/qos_monitor_${TS}.log"
SUMFILE="${LOGDIR}/qos_monitor_${TS}_summary.txt"
CAPTMP="/tmp/qos-monitor-${TS}.caplog"

need() { command -v "$1" >/dev/null 2>&1 || { echo "[ERRO] Falta '$1' (instala)."; exit 1; }; }
need tcpdump
need grep
need wc
need tail
need date

# =========================
# CABEÇALHO
# =========================
echo "==================== QoS MONITOR (LIVE) ====================" | tee "$LOGFILE" >/dev/null
{
  echo "Data/Hora início : $(date)"
  echo "Duração          : ${DUR}s"
  echo "Filtro tráfego   : src ${HOST_SRC} -> dst ${SERVER_DST}"
  echo "VoIP             : UDP dst port ${PORT_VOIP} | TOS ${TOS_EF} (DSCP EF)"
  echo "Vídeo            : UDP dst port ${PORT_VIDEO} | TOS ${TOS_AF} (DSCP AF41)"
  echo "Best Effort      : TCP dst port ${PORT_BE} | TOS ${TOS_BE} (DSCP 0)"
  echo "============================================================"
  echo
} | tee -a "$LOGFILE" >/dev/null

# =========================
# CAPTURA (background)
# =========================
# -l para line-buffer (melhor para "ao vivo")
# -tt para timestamp
# -n para não resolver nomes
# -vv para mostrar tos
# -K para não validar checksum (evita "bad udp cksum" a poluir)
FILTER="(src host ${HOST_SRC} and dst host ${SERVER_DST}) and ((udp and (dst port ${PORT_VOIP} or dst port ${PORT_VIDEO})) or (tcp and dst port ${PORT_BE}))"

rm -f "$CAPTMP" 2>/dev/null || true

tcpdump -i "$IFACE" -n -vv -tt -l -K "$FILTER" > "$CAPTMP" 2>/dev/null &
TCPDUMP_PID="$!"

cleanup() {
  kill "$TCPDUMP_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# esperar 0.5s para começar a encher o ficheiro
sleep 1

# =========================
# LIVE (60s)
# =========================
t0="$(date +%s)"

while :; do
  now="$(date +%s)"
  elapsed=$(( now - t0 ))
  [ "$elapsed" -ge "$DUR" ] && break

  # contadores (linhas que contêm o tos esperado + tipo tráfego)
  c_ef="$(grep -c "tos ${TOS_EF}.* UDP" "$CAPTMP" 2>/dev/null || echo 0)"
  c_af="$(grep -c "tos ${TOS_AF}.* UDP" "$CAPTMP" 2>/dev/null || echo 0)"
  c_be="$(grep -c "tos ${TOS_BE}.* TCP" "$CAPTMP" 2>/dev/null || echo 0)"

  # 1 exemplo recente (opcional)
  ex_ef="$(grep "tos ${TOS_EF}.* UDP" "$CAPTMP" 2>/dev/null | tail -n 1 || true)"
  ex_af="$(grep "tos ${TOS_AF}.* UDP" "$CAPTMP" 2>/dev/null | tail -n 1 || true)"
  ex_be="$(grep "tos ${TOS_BE}.* TCP" "$CAPTMP" 2>/dev/null | tail -n 1 || true)"

  clear
  echo "==================== QoS MONITOR (LIVE) ===================="
  echo "Tempo: ${elapsed}/${DUR}s  |  $(date)"
  echo "Interface: ${IFACE}  |  ${HOST_SRC} -> ${SERVER_DST}"
  echo
  echo "Contadores (a subir ao vivo):"
  echo " - EF   (tos ${TOS_EF}) : ${c_ef}"
  echo " - AF41 (tos ${TOS_AF}) : ${c_af}"
  echo " - BE   (tos ${TOS_BE}) : ${c_be}"
  echo
  echo "Último exemplo observado:"
  echo " - EF  : ${ex_ef:-<ainda nada>}"
  echo " - AF  : ${ex_af:-<ainda nada>}"
  echo " - BE  : ${ex_be:-<ainda nada>}"
  echo "============================================================"
  sleep 1
done

# parar captura
kill "$TCPDUMP_PID" 2>/dev/null || true
sleep 1

# =========================
# RELATÓRIO FINAL
# =========================
ENDDATE="$(date)"
EF_TOTAL="$(grep -c "tos ${TOS_EF}.* UDP" "$CAPTMP" 2>/dev/null || echo 0)"
AF_TOTAL="$(grep -c "tos ${TOS_AF}.* UDP" "$CAPTMP" 2>/dev/null || echo 0)"
BE_TOTAL="$(grep -c "tos ${TOS_BE}.* TCP" "$CAPTMP" 2>/dev/null || echo 0)"

EF_EX="$(grep "tos ${TOS_EF}.* UDP" "$CAPTMP" 2>/dev/null | head -n 1 || true)"
AF_EX="$(grep "tos ${TOS_AF}.* UDP" "$CAPTMP" 2>/dev/null | head -n 1 || true)"
BE_EX="$(grep "tos ${TOS_BE}.* TCP" "$CAPTMP" 2>/dev/null | head -n 1 || true)"

{
  echo
  echo "==================== RESUMO FINAL ===================="
  echo "Data/Hora fim     : ${ENDDATE}"
  echo "Ficheiro evidência: ${LOGFILE}"
  echo
  echo "Pacotes observados (tcpdump):"
  echo " - EF   (VoIP) : ${EF_TOTAL}"
  echo " - AF41 (Vídeo): ${AF_TOTAL}"
  echo " - BE   (TCP)  : ${BE_TOTAL}"
  echo
  echo "Exemplos capturados:"
  echo "--- EF ---"
  echo "${EF_EX:-<sem EF>}"
  echo "--- AF41 ---"
  echo "${AF_EX:-<sem AF41>}"
  echo "--- BE ---"
  echo "${BE_EX:-<sem BE>}"
  echo
  echo "Conclusão:"
  if [ "$EF_TOTAL" -gt 0 ] || [ "$AF_TOTAL" -gt 0 ]; then
    echo "✅ DSCP visível no caminho (EF/AF41 observados) — marcação confirmada."
  else
    echo "⚠️ Não foram observados EF/AF41 nesta interface — ou o tráfego não está marcado, ou o Monitor não está no caminho correto."
  fi
  echo "======================================================"
} | tee -a "$LOGFILE" >/dev/null

# resumo curto (para colar no relatório)
{
  echo "QoS Monitor — ${TS}"
  echo "Interface: ${IFACE} | ${HOST_SRC} -> ${SERVER_DST} | DUR=${DUR}s"
  echo "EF=${EF_TOTAL} | AF41=${AF_TOTAL} | BE=${BE_TOTAL}"
  echo "Evidência: ${LOGFILE}"
} > "$SUMFILE"

echo
echo "[OK] Relatório completo: $LOGFILE"
echo "[OK] Resumo curto     : $SUMFILE"
