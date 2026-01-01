#!/bin/sh
# Firewall da VNF-Access com logging de pings bloqueados

modprobe br_netfilter 2>/dev/null || true
echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables

iptables -F
iptables -X
iptables -P INPUT ACCEPT
iptables -P OUTPUT ACCEPT
iptables -P FORWARD ACCEPT

LNX="10.0.0.10"
SRV="10.0.0.20"

# 1) LOGA o ping bloqueado
iptables -A FORWARD -p icmp --icmp-type echo-request -s "$LNX" -d "$SRV" \
    -j LOG --log-prefix "PING_BLOCKED: " --log-level 4

# 2) BLOQUEIA o ping
iptables -A FORWARD -p icmp --icmp-type echo-request -s "$LNX" -d "$SRV" \
    -j DROP

echo "Regras carregadas na VNF-Access:"
iptables -L FORWARD -v --line-numbers

