#!/bin/sh
# Demo QoS "real" (HTTP vs HTTPS) com concorrência:
# - HTTP: vários downloads (BE)
# - HTTPS: tráfego contínuo via openssl s_server (EF) para não "acabar" antes do teste
# - VNF-Class: marca DSCP (443->EF, 80->BE)
# - VNF-Policy: HTB no egress (eth0) com priorização EF
#
# Password SSH das VNFs/Server: eve (via sshpass)

set -eu

### ====== AJUSTA AQUI (IPs de gestão) ======
MGMT_USER="root"
MGMT_PASS="eve"

SERVER_MGMT="192.168.2.20"   # gestão Server
ACCESS_MGMT="192.168.2.50"   # gestão VNF-Access
CLASS_MGMT="192.168.2.51"    # gestão VNF-Class
POLICE_MGMT="192.168.2.52"   # gestão VNF-Policy

SERVER_DATA_IP="10.0.0.20"   # IP do Server na rede de dados

POLICE_EGRESS_IF="eth0"      # confirmaste: eth0 é lado do Server
TOTAL_RATE="10mbit"
HTTPS_RATE="7mbit"
HTTP_RATE="3mbit"

TEST_SECS="${1:-40}"         # sugiro 40
HTTP_PARALLEL="${2:-5}"      # nº de downloads HTTP em paralelo

FILE_MB="200"                # tamanho download.bin
### =========================================

log() { printf "\n\033[1m[%s]\033[0m %s\n" "$(date +%H:%M:%S)" "$*"; }
ok()  { printf "\033[32m[OK]\033[0m %s\n" "$*"; }
warn(){ printf "\033[33m[AVISO]\033[0m %s\n" "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "Falta: $1"; exit 1; }; }

need ssh
need curl
need awk
need date
need sshpass

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/.ssh/known_hosts -o ConnectTimeout=5 -o LogLevel=ERROR"

rssh() {
  # $1 host ; $2 cmd
  sshpass -p "$MGMT_PASS" ssh $SSH_OPTS "${MGMT_USER}@${1}" "$2"
}

rssh_sh() {
  # $1 host ; stdin = script sh
  sshpass -p "$MGMT_PASS" ssh $SSH_OPTS "${MGMT_USER}@${1}" "sh -s"
}

have_timeout() { command -v timeout >/dev/null 2>&1; }

curl_bytes() {
  # $1 url ; $2 secs ; $3 extra opts
  URL="$1"
  SECS="$2"
  OPTS="$3"

  OUT="/tmp/curl_bytes_$$.$RANDOM.out"

  # arrancar curl em background a escrever para ficheiro
  ( curl $OPTS -s "$URL" -o "$OUT" ) >/dev/null 2>&1 &
  CPID=$!

  # deixar correr durante SECS
  sleep "$SECS" 2>/dev/null || true

  # terminar curl
  kill "$CPID" 2>/dev/null || true
  sleep 0.2 2>/dev/null || true
  kill -9 "$CPID" 2>/dev/null || true

  # contar bytes efetivamente escritos
  if [ -f "$OUT" ]; then
    wc -c < "$OUT" 2>/dev/null || echo 0
    rm -f "$OUT" 2>/dev/null || true
  else
    echo 0
  fi
}


mbit() { awk -v b="$1" -v t="$2" 'BEGIN{ if(t==0)t=1; printf "%.2f", (b*8)/(t*1000000) }'; }

log "0/5 (Sanity) Testar SSH..."
rssh "$SERVER_MGMT" "echo OK" >/dev/null
rssh "$ACCESS_MGMT" "echo OK" >/dev/null
rssh "$CLASS_MGMT"  "echo OK" >/dev/null
rssh "$POLICE_MGMT" "echo OK" >/dev/null
ok "SSH OK."

### 1) Server: preparar HTTP (nginx) + certs + s_server contínuo para HTTPS
log "1/5 Preparar Server: HTTP (nginx) + HTTPS contínuo (openssl s_server)"
rssh_sh "$SERVER_MGMT" <<SRV
set -eu

apk add --no-cache nginx openssl >/dev/null

# Conteúdo HTTP para gerar BE real
mkdir -p /var/www/localhost/htdocs
cd /var/www/localhost/htdocs
[ -f download.bin ] || dd if=/dev/zero of=download.bin bs=1M count=$FILE_MB >/dev/null 2>&1

# Cert self-signed (para s_server)
mkdir -p /etc/ssl/private /etc/ssl/certs
if [ ! -f /etc/ssl/private/server.key ] || [ ! -f /etc/ssl/certs/server.crt ]; then
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout /etc/ssl/private/server.key \
    -out /etc/ssl/certs/server.crt \
    -subj "/CN=$SERVER_DATA_IP" -days 2 >/dev/null 2>&1
fi

# Nginx só em HTTP (80) para download.bin
cat > /etc/nginx/http.d/default.conf << 'CONF'
server {
  listen 80;
  server_name _;
  root /var/www/localhost/htdocs;
  location / { autoindex on; }
}
CONF

# Garantir que nada ocupa 80/443
pkill -f "python3 -m http.server" 2>/dev/null || true
pkill -f "openssl s_server"        2>/dev/null || true

rc-service nginx restart >/dev/null 2>&1 || rc-service nginx start >/dev/null 2>&1

# Arrancar s_server contínuo em background com log (porta 443)
mkdir -p /var/log
nohup openssl s_server \
  -accept 443 \
  -cert /etc/ssl/certs/server.crt \
  -key /etc/ssl/private/server.key \
  -quiet -www \
  > /var/log/s_server_443.log 2>&1 &

echo "[OK] Server pronto:"
echo " - HTTP : http://$SERVER_DATA_IP/download.bin"
echo " - HTTPS: https://$SERVER_DATA_IP/  (openssl s_server -www)"
SRV
ok "Server OK (nginx+openssl)."

### 2) Access: permitir HTTP+HTTPS
log "2/5 VNF-Access: permitir HTTP e HTTPS"
rssh_sh "$ACCESS_MGMT" <<ACC
set -eu
SERVER_IP="$SERVER_DATA_IP"
modprobe br_netfilter 2>/dev/null || true
sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true

iptables -F FORWARD
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -p tcp -d "\$SERVER_IP" --dport 80  -j ACCEPT
iptables -A FORWARD -p tcp -d "\$SERVER_IP" --dport 443 -j ACCEPT

echo "[OK] Access: HTTP/HTTPS permitidos"
ACC
ok "VNF-Access OK."

### 3) Class: DSCP
log "3/5 VNF-Class: marcar DSCP (HTTPS=EF, HTTP=BE)"
rssh_sh "$CLASS_MGMT" <<CLS
set -eu
modprobe br_netfilter 2>/dev/null || true
sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null 2>&1 || true

iptables -t mangle -F PREROUTING
iptables -t mangle -A PREROUTING -i br0 -p tcp --dport 443 -j DSCP --set-dscp 0x2e
iptables -t mangle -A PREROUTING -i br0 -p tcp --dport 80  -j DSCP --set-dscp 0x00

echo "[OK] Class: regras DSCP aplicadas"
CLS
ok "VNF-Class OK."

### 4) Policy: HTB no eth0 (lado server)
log "4/5 VNF-Policy: HTB em $POLICE_EGRESS_IF"
rssh_sh "$POLICE_MGMT" <<POL
set -eu
IFACE="$POLICE_EGRESS_IF"

tc qdisc del dev "\$IFACE" root 2>/dev/null || true
tc qdisc add dev "\$IFACE" root handle 1: htb default 20
tc class add dev "\$IFACE" parent 1: classid 1:1 htb rate "$TOTAL_RATE" ceil "$TOTAL_RATE"

tc class add dev "\$IFACE" parent 1:1 classid 1:10 htb rate "$HTTPS_RATE" ceil "$TOTAL_RATE" prio 0
tc class add dev "\$IFACE" parent 1:1 classid 1:20 htb rate "$HTTP_RATE"  ceil "$TOTAL_RATE" prio 2

# EF=46<<2=0xb8 ; BE=0x00
tc filter add dev "\$IFACE" protocol ip parent 1: prio 1 u32 match ip tos 0xb8 0xfc flowid 1:10
tc filter add dev "\$IFACE" protocol ip parent 1: prio 2 u32 match ip tos 0x00 0xfc flowid 1:20

echo "[OK] Policy: HTB ativo em \$IFACE"
POL
ok "VNF-Policy OK."

### 5) Teste no Host: N x HTTP + 1 x HTTPS contínuo
URL_HTTP="http://${SERVER_DATA_IP}/download.bin"
URL_HTTPS="https://${SERVER_DATA_IP}/video.bin"   # s_server -www responde aqui

log "5/5 TESTE (Host): ${HTTP_PARALLEL}x HTTP (download) + 1x HTTPS contínuo (s_server) durante ${TEST_SECS}s"
echo "HTTP : $URL_HTTP"
echo "HTTPS: $URL_HTTPS"
echo

TMPD="/tmp/sfcqos.$$"
mkdir -p "$TMPD"

# HTTP concorrente (BE)
i=1
while [ "$i" -le "$HTTP_PARALLEL" ]; do
  ( curl_bytes "$URL_HTTP" "$TEST_SECS" "" > "$TMPD/http_$i.bytes" ) &
  i=$((i+1))
done

# HTTPS contínuo (EF) - usa -k por cert self-signed
( curl_bytes "$URL_HTTPS" "$TEST_SECS" "-k" > "$TMPD/https.bytes" ) &

wait

# somar HTTP
HTTP_BYTES=0
i=1
while [ "$i" -le "$HTTP_PARALLEL" ]; do
  B="$(cat "$TMPD/http_$i.bytes" 2>/dev/null || echo 0)"
  HTTP_BYTES=$((HTTP_BYTES + B))
  i=$((i+1))
done

HTTPS_BYTES="$(cat "$TMPD/https.bytes" 2>/dev/null || echo 0)"
rm -rf "$TMPD" 2>/dev/null || true

HTTP_MBIT="$(mbit "$HTTP_BYTES" "$TEST_SECS")"
HTTPS_MBIT="$(mbit "$HTTPS_BYTES" "$TEST_SECS")"

echo "==================== RESULTADOS ===================="
echo "HTTP  (total ${HTTP_PARALLEL} flows): ${HTTP_MBIT} Mbit/s  (bytes: ${HTTP_BYTES})"
echo "HTTPS (1 flow contínuo)       : ${HTTPS_MBIT} Mbit/s  (bytes: ${HTTPS_BYTES})"
echo "Nota: o total HTTP soma vários fluxos; o importante é o HTTPS manter throughput sob carga."
echo "==========================================================="

log "PROVAS PARA O DOCENTE (prints recomendados)"
echo "1) VNF-Class (contadores DSCP):"
rssh "$CLASS_MGMT" "iptables -t mangle -L PREROUTING -v -n --line-numbers | sed -n '1,120p'"

echo
echo "2) VNF-Policy (bytes por classe HTB em $POLICE_EGRESS_IF):"
rssh "$POLICE_MGMT" "tc -s class show dev $POLICE_EGRESS_IF | sed -n '1,220p'"

echo
ok "Demo concluída."

