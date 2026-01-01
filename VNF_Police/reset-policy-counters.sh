#!/bin/sh
set -eu

DEV="${1:-eth0}"

echo "[POLICY] Reset de contadores (reaplicar QoS) em: $DEV"

# Remover qdisc (isto limpa contadores)
tc qdisc del dev "$DEV" root 2>/dev/null || true

# Reaplicar HTB + classes
tc qdisc add dev "$DEV" root handle 1: htb default 30
tc class add dev "$DEV" parent 1: classid 1:1 htb rate 50mbit ceil 50mbit

tc class add dev "$DEV" parent 1:1 classid 1:10 htb rate 1mbit ceil 2mbit prio 0
tc class add dev "$DEV" parent 1:1 classid 1:20 htb rate 5mbit ceil 10mbit prio 1
tc class add dev "$DEV" parent 1:1 classid 1:30 htb rate 2mbit ceil 50mbit prio 2

# Filtros DSCP
tc filter add dev "$DEV" parent 1: protocol ip prio 10 u32 \
  match ip dsfield 0xb8 0xfc flowid 1:10

tc filter add dev "$DEV" parent 1: protocol ip prio 20 u32 \
  match ip dsfield 0x88 0xfc flowid 1:20

tc filter add dev "$DEV" parent 1: protocol ip prio 30 u32 \
  match ip dsfield 0x00 0xfc flowid 1:30

echo "[POLICY] OK. Contadores após reset:"
tc -s class show dev "$DEV"
