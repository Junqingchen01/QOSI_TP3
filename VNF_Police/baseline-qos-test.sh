#!/bin/sh
set -eu

### =========================
### BASELINE QoS (SEM QoS)
### =========================

# Gestão
IP_HOST="192.168.2.10"
IP_SERVER="192.168.2.20"

# IP de dados
DATA_SERVER="10.0.0.20"

# Credenciais
SSH_PASS="eve"

# Duração
DUR=60

# Portos
PORT_VOIP=5201
PORT_VIDEO=5202
PORT_BE=5203

# Taxas
RATE_VOIP="200k"
RATE_VIDEO="10M"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

ssh_do() {
  sshpass -p "$SSH_PASS" ssh $SSH_OPTS "$@"
}

echo "======================================================"
echo " BASELINE QoS — SEM CLASSIFICAÇÃO / SEM SHAPING"
echo "======================================================"
echo "Host:   $IP_HOST"
echo "Server: $IP_SERVER"
echo "Dados : $DATA_SERVER"
echo "Tempo : ${DUR}s"
echo "======================================================"

# -------------------------------------------------------
# 1. Garantir que NÃO existe QoS
# -------------------------------------------------------
echo "[1/4] Remover qualquer QoS existente..."
tc qdisc del dev eth0 root 2>/dev/null || true
echo "OK — sem tc ativo"

# -------------------------------------------------------
# 2. Iniciar iperf no servidor
# -------------------------------------------------------
echo "[2/4] Iniciar iperf no servidor..."

ssh_do root@$IP_SERVER "
  killall iperf3 2>/dev/null || true
  nohup iperf3 -s -B $DATA_SERVER -p $PORT_VOIP  >/dev/null 2>&1 &
  nohup iperf3 -s -B $DATA_SERVER -p $PORT_VIDEO >/dev/null 2>&1 &
  nohup iperf3 -s -B $DATA_SERVER -p $PORT_BE    >/dev/null 2>&1 &
"

# -------------------------------------------------------
# 3. Gerar tráfego no Host
# -------------------------------------------------------
echo "[3/4] A gerar tráfego (baseline)..."

ssh_do root@$IP_HOST "
  killall iperf3 2>/dev/null || true

  nohup iperf3 -c $DATA_SERVER -u -b $RATE_VOIP  -t $DUR -p $PORT_VOIP  >/tmp/iperf_voip.txt  2>&1 &
  nohup iperf3 -c $DATA_SERVER -u -b $RATE_VIDEO -t $DUR -p $PORT_VIDEO >/tmp/iperf_video.txt 2>&1 &
  nohup iperf3 -c $DATA_SERVER       -t $DUR -p $PORT_BE              >/tmp/iperf_be.txt    2>&1 &
"

# -------------------------------------------------------
# 4. Aguardar e mostrar resultados
# -------------------------------------------------------
echo "[4/4] A aguardar ${DUR}s..."
sleep "$DUR"

echo
echo "================ RESULTADOS BASELINE ================"

echo "--- VoIP ---"
ssh_do root@$IP_HOST "tail -n 3 /tmp/iperf_voip.txt"

echo
echo "--- Vídeo ---"
ssh_do root@$IP_HOST "tail -n 3 /tmp/iperf_video.txt"

echo
echo "--- Best Effort ---"
ssh_do root@$IP_HOST "tail -n 3 /tmp/iperf_be.txt"

echo
echo "======================================================"
echo "Baseline concluído — tráfego sem QoS nem DSCP"
