#!/bin/sh
# Dashboard fixa (refresh), Alpine/BusyBox OK

CLASS_IP="192.168.2.51"
POLICY_IP="192.168.2.52"
PASS="eve"
IFACE="${IFACE:-br0}"
POLICY_DEV="${POLICY_DEV:-eth0}"
INTERVAL="${INTERVAL:-1}"

LOG="/var/log/qos_dash_live_$(date +%F_%H-%M-%S).log"
CSV="/var/log/qos_dash_live_$(date +%F_%H-%M-%S).csv"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=2"

need(){ command -v "$1" >/dev/null 2>&1; }
if ! need sshpass || ! need tcpdump; then
  echo "[ERRO] Precisas de sshpass e tcpdump."
  echo "Alpine: apk add --no-cache sshpass tcpdump"
  exit 1
fi

ssh_cmd() { sshpass -p "$PASS" ssh $SSH_OPTS root@"$1" "$2" 2>/dev/null; }

get_class_counts() {
  out="$(ssh_cmd "$CLASS_IP" "iptables -t mangle -L PREROUTING -v -n")"
  p443="$(printf "%s\n" "$out" | awk '/tcp dpt:443/ {print $1; exit}')" ; b443="$(printf "%s\n" "$out" | awk '/tcp dpt:443/ {print $2; exit}')"
  p80="$(printf "%s\n" "$out"  | awk '/tcp dpt:80/  {print $1; exit}')" ; b80="$(printf "%s\n" "$out"  | awk '/tcp dpt:80/  {print $2; exit}')"
  echo "${p443:-0} ${b443:-0} ${p80:-0} ${b80:-0}"
}

get_policy_counts() {
  out="$(ssh_cmd "$POLICY_IP" "tc -s class show dev $POLICY_DEV")"
  b10="$(printf "%s\n" "$out" | awk '$1=="class"&&$3=="1:10"{f=1} f&&$1=="Sent"{print $2; exit}')" ; p10="$(printf "%s\n" "$out" | awk '$1=="class"&&$3=="1:10"{f=1} f&&$1=="Sent"{print $4; exit}')"
  b20="$(printf "%s\n" "$out" | awk '$1=="class"&&$3=="1:20"{f=1} f&&$1=="Sent"{print $2; exit}')" ; p20="$(printf "%s\n" "$out" | awk '$1=="class"&&$3=="1:20"{f=1} f&&$1=="Sent"{print $4; exit}')"
  echo "${p10:-0} ${b10:-0} ${p20:-0} ${b20:-0}"
}

sniff_1s() {
  cap="$(timeout 1 tcpdump -ni "$IFACE" 'tcp and (port 80 or port 443)' 2>/dev/null || true)"
  http="$(printf "%s\n" "$cap" | awk '/\.80[[:space:]]/ {c++} END{print c+0}')"
  https="$(printf "%s\n" "$cap" | awk '/\.443[[:space:]]/ {c++} END{print c+0}')"
  echo "$http $https"
}

rate() { # delta/seg
  a="${1:-0}"; b="${2:-0}"
  echo $((a-b))
}

mkdir -p /var/log 2>/dev/null || true
echo "ts,cls443_pkts,cls443_bytes,cls80_pkts,cls80_bytes,pol10_pkts,pol10_bytes,pol20_pkts,pol20_bytes,sniff_http_pkts,sniff_https_pkts" > "$CSV"

prev_c="$(get_class_counts)"
prev_p="$(get_policy_counts)"

prev_p443="$(echo "$prev_c" | awk '{print $1}')" ; prev_b443="$(echo "$prev_c" | awk '{print $2}')"
prev_p80="$(echo "$prev_c"  | awk '{print $3}')" ; prev_b80="$(echo "$prev_c"  | awk '{print $4}')"

prev_p10="$(echo "$prev_p" | awk '{print $1}')" ; prev_b10="$(echo "$prev_p" | awk '{print $2}')"
prev_p20="$(echo "$prev_p" | awk '{print $3}')" ; prev_b20="$(echo "$prev_p" | awk '{print $4}')"

while :; do
  ts="$(date +%F\ %T)"
  c="$(get_class_counts)"; p="$(get_policy_counts)"; s="$(sniff_1s)"

  p443="$(echo "$c" | awk '{print $1}')" ; b443="$(echo "$c" | awk '{print $2}')"
  p80="$(echo "$c"  | awk '{print $3}')" ; b80="$(echo "$c"  | awk '{print $4}')"

  p10="$(echo "$p" | awk '{print $1}')" ; b10="$(echo "$p" | awk '{print $2}')"
  p20="$(echo "$p" | awk '{print $3}')" ; b20="$(echo "$p" | awk '{print $4}')"

  sniff_http="$(echo "$s" | awk '{print $1}')"
  sniff_https="$(echo "$s" | awk '{print $2}')"

  # taxas
  r443="$(rate "$p443" "$prev_p443")"
  r80="$(rate "$p80" "$prev_p80")"
  r10="$(rate "$p10" "$prev_p10")"
  r20="$(rate "$p20" "$prev_p20")"

  # dashboard fixa
  clear 2>/dev/null || true
  echo "==================== QoS DASHBOARD  ===================="
  echo "Hora: $ts | IFACE=$IFACE | Class=$CLASS_IP | Policy=$POLICY_IP ($POLICY_DEV)"
  echo "--------------------------------------------------------------"
  printf "CLASS (iptables mangle)  443(EF): %s pkts (+%s/s) | 80(BE): %s pkts (+%s/s)\n" "$p443" "$r443" "$p80" "$r80"
  echo "--------------------------------------------------------------"
  printf "POLICY (tc/HTB)          1:10(EF): %s pkts (+%s/s) | 1:20(BE): %s pkts (+%s/s)\n" "$p10" "$r10" "$p20" "$r20"
  echo "--------------------------------------------------------------"
  printf "TRÁFEGO visto no Monitor (tcpdump ~1s)   HTTP(80): %s pkts | HTTPS(443): %s pkts\n" "$sniff_http" "$sniff_https"
  echo "--------------------------------------------------------------"
  echo "CSV: $CSV"
  echo "LOG: $LOG"
  echo "SAIR: Ctrl+C"
  echo "=============================================================="

  # guardar log simples (1 linha por ciclo) + CSV
  echo "$ts CLASS 443 pkts=$p443 bytes=$b443 | 80 pkts=$p80 bytes=$b80 | POLICY 1:10 pkts=$p10 bytes=$b10 | 1:20 pkts=$p20 bytes=$b20 | SNIFF http=$sniff_http https=$sniff_https" >> "$LOG"
  echo "$ts,$p443,$b443,$p80,$b80,$p10,$b10,$p20,$b20,$sniff_http,$sniff_https" >> "$CSV"

  prev_p443="$p443"; prev_b443="$b443"; prev_p80="$p80"; prev_b80="$b80"
  prev_p10="$p10";   prev_b10="$b10";   prev_p20="$p20"; prev_b20="$b20"

  sleep "$INTERVAL"
done
