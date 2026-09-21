#!/usr/bin/env bash
# ============================================================================
#  Сетевой тюнинг хоста под роль прокси-ноды.
#
#  Контейнеры работают с network_mode: host, поэтому sysctl задаются на
#  хосте, а не в docker-compose (в host-режиме секция sysctls запрещена).
#
#  Запуск: sudo ./scripts/tune-sysctl.sh
# ============================================================================
set -euo pipefail

RED=$'\033[31m'; GREEN=$'\033[32m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
[[ $EUID -eq 0 ]] || { echo "${RED}Нужны права root: sudo $0${OFF}" >&2; exit 1; }

CONF=/etc/sysctl.d/99-remnanode.conf

cat > "$CONF" <<'EOF'
# Настройки для ноды Remnawave: много одновременных TCP-соединений,
# весь входящий трафик через один порт 443.

# BBR + fq заметно улучшают поведение на длинных и нагруженных каналах.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Очередь на приём новых соединений. Дефолтных 4096 мало, когда на 443
# одновременно приходят сотни клиентов.
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 32768

# Быстрее освобождать порты после закрытия соединений.
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Диапазон локальных портов: каждое исходящее соединение к сайту занимает один.
net.ipv4.ip_local_port_range = 10240 65535

# Keepalive: быстрее вычищать оборванные сессии мобильных клиентов.
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Буферы под высокую пропускную способность.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# TCP Fast Open для входящих и исходящих.
net.ipv4.tcp_fastopen = 3

# Общий потолок открытых файлов в системе.
fs.file-max = 2097152
EOF

echo "${BOLD}Применяю $CONF${OFF}"
sysctl --system >/dev/null

echo
echo "${GREEN}✓${OFF} Готово. Проверка:"
echo "  tcp_congestion_control = $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "  default_qdisc          = $(sysctl -n net.core.default_qdisc)"
echo "  somaxconn              = $(sysctl -n net.core.somaxconn)"

if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" != "bbr" ]]; then
  echo
  echo "BBR не включился. Обычно это значит, что модуль не загружен:"
  echo "  modprobe tcp_bbr && echo tcp_bbr >> /etc/modules-load.d/modules.conf"
  echo "На очень старых ядрах (<4.9) BBR недоступен — это не критично."
fi
