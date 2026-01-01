#!/bin/sh
set -eu

echo "[CLASS] A zerar contadores do iptables (tabela mangle)..."
iptables -t mangle -Z

echo "[CLASS] OK. Contadores após reset:"
iptables -t mangle -L -v
