#!/bin/sh
set -eu

### =========================
### CONFIG (podes alterar via env)
### =========================
# ATENÇÃO: na tua tipologia, normalmente o shaping deve ser no lado de saída para o "Server".
# Se no teu VNF-Policy o lado para o Server é eth0, deixa eth0. Se for eth1, muda para eth1.
DEV_POLICY="${DEV_POLICY:-eth0}"

# Gestão (SSH)
IP_CLASS="${IP_CLASS:-192.168.2.51}"     # VNF-Class (gestão)
IP_HOST="${IP_HOST:-192.168.2.10}"       # Host (gestão/SSH)
IP_SERVER="${IP_SERVER:-192.168.2.20}"   # Server (gestão/SSH)

# (Opcional) Monitor para receber o resumo por SSH (ficheiro em /var/monitor)
IP_MONITOR="${IP_MONITOR:-}"             # ex: 192.168.2.53  (deixa vazio se não quiseres)

# Dados (tráfego real do iperf3)
DATA_SERVER="${DATA_SERVER:-10.0.0.20}"  # Server (plano de dados)

SSH_PASS="${SSH_PASS:-eve}"

DUR="${DUR:-60}"                         # segundos
RATE_VOIP="${RATE_VOIP:-200k}"           # VoIP UDP
RATE_VIDEO="${RATE_VIDEO:-10M}"          # Vídeo UDP

PORT_VOIP="${PORT_VOIP:-5201}"
PORT_VIDEO="${PORT_VIDEO:-5202}"
PORT_BE="${PORT_BE:-5203}"

CPORT_VOIP="${CPORT_VOIP:-4000}"         # sport -> EF
CPORT_VIDEO="${CPORT_VIDEO:-5000}"       # sport -> AF
### =========================

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4 -o ServerAliveInterval=2 -o ServerAliveCountMax=2"

ssh_do() {
  sshpass -p "$SSH_PASS" ssh $SSH_OPTS "$@"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[ERRO] Falta '$1'."; exit 1; }; }

echo "============================================================"
echo "[RUN] Teste QoS ${DUR}s"
echo " - Policy DEV : ${DEV_POLICY}"
echo " - Class (SSH): ${IP_CLASS}"
echo " - Host  (SSH): ${IP_HOST}"
echo " - Server(SSH): ${IP_SERVER}"
echo " - Server(DATA): ${DATA_SERVER}"
[ -n "$IP_MONITOR" ] && echo " - Monitor(SSH): ${IP_MONITOR}"
echo "============================================================"

# ---------- 0) Verificações ----------
need_cmd tc
need_cmd sshpass

echo "[0/6] Testar SSH..."
ssh_do root@"$IP_CLASS"  "echo OK_CLASS"  >/dev/null
ssh_do root@"$IP_HOST"   "echo OK_HOST"   >/dev/null
ssh_do root@"$IP_SERVER" "echo OK_SERVER" >/dev/null
[ -n "$IP_MONITOR" ] && ssh_do root@"$IP_MONITOR" "echo OK_MONITOR" >/dev/null || true
echo "[0/6] OK"

# ---------- 1) Preparar VNF-Class (br_netfilter + DSCP marking) ----------
echo "[1/6] Preparar VNF-Class (bridge + marcação DSCP)..."

ssh_do root@"$IP_CLASS" "sh -eu -c '
  # 1) garantir módulos (para bridges e alvo DSCP)
  modprobe br_netfilter 2>/dev/null || true
  modprobe xt_DSCP 2>/dev/null || true
  modprobe iptable_mangle 2>/dev/null || true

  # 2) permitir iptables ver tráfego em bridge
  sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true
  sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null 2>&1 || true

  # 3) aplicar regras de marcação (PREROUTING mangle)
  iptables -t mangle -F PREROUTING || true

  # VoIP: UDP sport 4000 -> DSCP EF (46) => 0x2e
  iptables -t mangle -A PREROUTING -p udp --sport $CPORT_VOIP  -j DSCP --set-dscp-class EF

  # Vídeo: UDP sport 5000 -> DSCP AF41 (34) => 0x22
  iptables -t mangle -A PREROUTING -p udp --sport $CPORT_VIDEO -j DSCP --set-dscp-class AF41

  # 4) zerar contadores após aplicar regras (para o teste começar limpo)
  iptables -t mangle -Z

  echo OK_CLASS_READY
'" >/dev/null

# ---------- 2) Preparar QoS no VNF-Policy (tc) ----------
echo "[2/6] Aplicar QoS no VNF-Policy (tc HTB + filtros DSCP)..."

tc qdisc del dev "$DEV_POLICY" root >/dev/null 2>&1 || true
tc qdisc add dev "$DEV_POLICY" root handle 1: htb default 30

tc class add dev "$DEV_POLICY" parent 1: classid 1:1 htb rate 50mbit ceil 50mbit

# EF / AF / BE
tc class add dev "$DEV_POLICY" parent 1:1 classid 1:10 htb rate 1mbit ceil 2mbit  prio 0
tc class add dev "$DEV_POLICY" parent 1:1 classid 1:20 htb rate 5mbit ceil 10mbit prio 1
tc class add dev "$DEV_POLICY" parent 1:1 classid 1:30 htb rate 2mbit ceil 50mbit prio 2

# filtros DSCP (EF=0xb8, AF41=0x88, BE=0x00) — atenção: dsfield inclui ECN, por isso máscara 0xfc
tc filter del dev "$DEV_POLICY" parent 1: protocol ip >/dev/null 2>&1 || true
tc filter add dev "$DEV_POLICY" parent 1: protocol ip prio 10 u32 match ip dsfield 0xb8 0xfc flowid 1:10
tc filter add dev "$DEV_POLICY" parent 1: protocol ip prio 20 u32 match ip dsfield 0x88 0xfc flowid 1:20
tc filter add dev "$DEV_POLICY" parent 1: protocol ip prio 30 u32 match ip dsfield 0x00 0xfc flowid 1:30

# ---------- 3) Arrancar iperf3 no Server (3 portas, bind ao IP de dados) ----------
echo "[3/6] Iniciar iperf3 no Server (3 portas, bind ${DATA_SERVER})..."
ssh_do root@"$IP_SERVER" "sh -eu -c '
  killall iperf3 2>/dev/null || true
  nohup iperf3 -s -B $DATA_SERVER -p $PORT_VOIP  >/dev/null 2>&1 &
  nohup iperf3 -s -B $DATA_SERVER -p $PORT_VIDEO >/dev/null 2>&1 &
  nohup iperf3 -s -B $DATA_SERVER -p $PORT_BE    >/dev/null 2>&1 &
  echo OK_SERVER_READY
'" >/dev/null

# ---------- 4) Arrancar clientes no Host (em paralelo) ----------
echo "[4/6] Iniciar tráfego no Host (VoIP+Vídeo+BE em paralelo por ${DUR}s)..."
ssh_do root@"$IP_HOST" "sh -eu -c '
  killall iperf3 2>/dev/null || true

  nohup iperf3 -c $DATA_SERVER -u -b $RATE_VOIP  -t $DUR -p $PORT_VOIP  --cport $CPORT_VOIP  >/tmp/iperf_voip.txt  2>&1 &
  nohup iperf3 -c $DATA_SERVER -u -b $RATE_VIDEO -t $DUR -p $PORT_VIDEO --cport $CPORT_VIDEO >/tmp/iperf_video.txt 2>&1 &
  nohup iperf3 -c $DATA_SERVER       -t $DUR -p $PORT_BE                         >/tmp/iperf_be.txt    2>&1 &
  echo OK_HOST_TRAFFIC
'" >/dev/null

# ---------- 5) Monitorização ao vivo ----------
echo "[5/6] Contadores ao vivo (${DUR}s)..."

tc_snapshot() { tc -s class show dev "$DEV_POLICY"; }

# >>> ALTERAÇÃO MÍNIMA #1: adicionar -x (sem K/M) <<<
ipt_snapshot() {
  ssh_do root@"$IP_CLASS" "iptables -t mangle -L PREROUTING -v -n -x --line-numbers" 2>/dev/null || true
}

dscp_check() { ssh_do root@"$IP_CLASS" "iptables -t mangle -S PREROUTING" 2>/dev/null || true; }

TC_START="$(tc_snapshot)"
IPT_START="$(ipt_snapshot)"

t0="$(date +%s)"
while :; do
  now="$(date +%s)"
  elapsed=$(( now - t0 ))
  [ "$elapsed" -ge "$DUR" ] && break

  clear
  echo "==================== LIVE QoS ===================="
  echo "Tempo: ${elapsed}s / ${DUR}s | $(date)"
  echo "-------------------- CLASS (iptables) ------------"
  ipt_snapshot
  echo
  echo "-------------------- POLICY (tc) -----------------"
  tc_snapshot
  echo "=================================================="
  sleep 1
done

# ---------- 6) Parar iperf e gerar resumo ----------
echo "[6/6] A parar iperf e a gerar resumo..."
ssh_do root@"$IP_HOST"   "killall iperf3 >/dev/null 2>&1 || true" >/dev/null || true
ssh_do root@"$IP_SERVER" "killall iperf3 >/dev/null 2>&1 || true" >/dev/null || true

TC_END="$(tc_snapshot)"
IPT_END="$(ipt_snapshot)"

extract_tc() {
  echo "$1" | awk '
    $1=="class" && $2=="htb" { cls=$3; next }
    $1=="Sent" {
      sent=$2; over=0;
      for(i=1;i<=NF;i++) if($i=="overlimits") over=$(i+1);
      if(cls!=""){ printf "%s %s %s\n", cls, sent, over; cls="" }
    }'
}

# >>> ALTERAÇÃO MÍNIMA #2: procurar "spt:4000" e "spt:5000" (formato real do iptables -L) <<<
extract_ipt_lines() {
  echo "$1" | awk '
    $2 ~ /^[0-9]+$/ {
      pkts=$2; bytes=$3;
      if ($0 ~ /spt:4000/) print "SPORT4000", pkts, bytes;
      if ($0 ~ /spt:5000/) print "SPORT5000", pkts, bytes;
    }'
}

delta_line() {
  key="$1"
  a="$(echo "$2" | awk -v k="$key" '$1==k {print $2" "$3}')"
  b="$(echo "$3" | awk -v k="$key" '$1==k {print $2" "$3}')"
  a1="$(echo "$a" | awk '{print $1+0}')"; a2="$(echo "$a" | awk '{print $2+0}')"
  b1="$(echo "$b" | awk '{print $1+0}')"; b2="$(echo "$b" | awk '{print $2+0}')"
  echo $((b1-a1)) $((b2-a2))
}

TC_S0="$(extract_tc "$TC_START")"
TC_S1="$(extract_tc "$TC_END")"

IP_S0="$(extract_ipt_lines "$IPT_START")"
IP_S1="$(extract_ipt_lines "$IPT_END")"

d_110="$(delta_line "1:10" "$TC_S0" "$TC_S1")"
d_120="$(delta_line "1:20" "$TC_S0" "$TC_S1")"
d_130="$(delta_line "1:30" "$TC_S0" "$TC_S1")"

d_4000="$(delta_line "SPORT4000" "$IP_S0" "$IP_S1")"
d_5000="$(delta_line "SPORT5000" "$IP_S0" "$IP_S1")"

VOIP_TAIL="$(ssh_do root@"$IP_HOST" "tail -n 2 /tmp/iperf_voip.txt 2>/dev/null" || true)"
VIDEO_TAIL="$(ssh_do root@"$IP_HOST" "tail -n 2 /tmp/iperf_video.txt 2>/dev/null" || true)"
BE_TAIL="$(ssh_do root@"$IP_HOST" "tail -n 2 /tmp/iperf_be.txt 2>/dev/null" || true)"

CLASS_RULES="$(dscp_check | tr '\n' '|' )"

SUMMARY="$(cat <<SUM
==================== RESUMO (colar no relatório) ====================
Objetivo:
- Demonstrar um mecanismo QoS fim-a-fim com (i) CLASSIFICAÇÃO/MARCAÇÃO DSCP no VNF-Class e
  (ii) ENCAMINHAMENTO/SHAPING por classes no VNF-Policy.

Topologia (controlo e dados):
- Gestão via SSH (rede 192.168.2.0/24): Host=${IP_HOST}, Server=${IP_SERVER}, Class=${IP_CLASS}
- Tráfego de dados iperf3 enviado para ${DATA_SERVER} (plano de dados).

Tráfego gerado (${DUR}s, em paralelo):
- VoIP: UDP, --cport ${CPORT_VOIP}, taxa ${RATE_VOIP}
- Vídeo: UDP, --cport ${CPORT_VIDEO}, taxa ${RATE_VIDEO}
- Best Effort: TCP (sem marcação)

Configuração no VNF-Class:
- Bridge com br_netfilter + net.bridge.bridge-nf-call-iptables=1 para iptables ver tráfego bridged.
- Regras mangle/PREROUTING aplicadas (formato iptables -S):
  ${CLASS_RULES}

Evidência de marcação (contadores no VNF-Class durante o teste):
- sport ${CPORT_VOIP}  (VoIP -> DSCP EF):  +$(echo "$d_4000" | awk '{print $1}') pkts, +$(echo "$d_4000" | awk '{print $2}') bytes
- sport ${CPORT_VIDEO} (Vídeo -> AF41):   +$(echo "$d_5000" | awk '{print $1}') pkts, +$(echo "$d_5000" | awk '{print $2}') bytes

Evidência de enforcement no VNF-Policy (tc HTB em ${DEV_POLICY}):
- Classe 1:10 (EF/VoIP):  +$(echo "$d_110" | awk '{print $1}') bytes, +$(echo "$d_110" | awk '{print $2}') overlimits
- Classe 1:20 (AF/Vídeo): +$(echo "$d_120" | awk '{print $1}') bytes, +$(echo "$d_120" | awk '{print $2}') overlimits
- Classe 1:30 (BE):       +$(echo "$d_130" | awk '{print $1}') bytes, +$(echo "$d_130" | awk '{print $2}') overlimits

Saída iperf3 (Host) — últimas linhas:
- VoIP:  $(echo "$VOIP_TAIL"  | tr '\n' ' ' | sed 's/  */ /g')
- Vídeo: $(echo "$VIDEO_TAIL" | tr '\n' ' ' | sed 's/  */ /g')
- BE:    $(echo "$BE_TAIL"    | tr '\n' ' ' | sed 's/  */ /g')
=====================================================================
SUM
)"

echo
echo "$SUMMARY"

if [ -n "$IP_MONITOR" ]; then
  ts="$(date +%F_%H-%M-%S)"
  ssh_do root@"$IP_MONITOR" "mkdir -p /var/monitor && cat >> /var/monitor/qos-summary-${ts}.log" <<EOM || true
$SUMMARY
EOM
  ssh_do root@"$IP_MONITOR" "logger -t QOS_SUMMARY \"QoS run ${ts} gravado em /var/monitor/qos-summary-${ts}.log\"" >/dev/null 2>&1 || true
  echo "[INFO] Resumo enviado para o Monitor: /var/monitor/qos-summary-${ts}.log"
fi
