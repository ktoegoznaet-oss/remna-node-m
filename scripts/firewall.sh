#!/usr/bin/env bash
# ============================================================================
#  Фаервол ноды (ufw).
#
#  Логика простая: снаружи доступны только 443 (клиенты) и порт управления
#  нодой — и то лишь с IP панели. Всё остальное закрыто.
#
#  Бэкенд-порты инбаундов уже слушаются на 127.0.0.1, так что фаервол здесь
#  второй слой защиты, а не единственный. Так и надо.
#
#  ВНИМАНИЕ: скрипт меняет правила доступа к серверу. Если ошибётесь с
#  ADMIN_IP — потеряете SSH. Держите открытой вторую SSH-сессию или консоль
#  провайдера, пока не убедитесь, что доступ сохранился.
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
die() { echo "${RED}ОШИБКА:${OFF} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "нужны права root: sudo $0"
[[ -f .env ]] || die ".env не найден."

set -a; source .env; set +a
: "${NODE_PORT:=2231}"
SSH_PORT="${SSH_PORT:-22}"

command -v ufw >/dev/null 2>&1 || die "ufw не установлен: apt-get install -y ufw
     (для nftables/iptables см. комментарий в конце этого файла)"

[[ -n "${PANEL_IP:-}" ]] || die "в .env не задан PANEL_IP — без него порт управления
     пришлось бы открыть всему интернету, а это плохая идея."

echo "${BOLD}Будут применены правила:${OFF}"
echo "  политика по умолчанию      : входящие DENY, исходящие ALLOW"
if [[ -n "${ADMIN_IP:-}" ]]; then
  echo "  SSH ($SSH_PORT/tcp)              : только с $ADMIN_IP"
else
  echo "  SSH ($SSH_PORT/tcp)              : ${YELLOW}со всех адресов${OFF} (ADMIN_IP в .env не задан)"
fi
echo "  443/tcp                    : со всех адресов (клиентский трафик)"
echo "  $NODE_PORT/tcp                   : только с $PANEL_IP (панель Remnawave)"
echo "  ${PORT_TCP:-4433}, ${PORT_GRPC:-5443}, ${PORT_XHTTP:-8443}          : наружу закрыты"
echo

if [[ -n "${ADMIN_IP:-}" ]]; then
  CUR_IP="$(who am i 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p')"
  if [[ -n "$CUR_IP" && "$CUR_IP" != "$ADMIN_IP" ]]; then
    echo "${RED}${BOLD}Опасность:${OFF} вы подключены с $CUR_IP, а SSH будет открыт только для $ADMIN_IP."
    echo "После применения правил текущая сессия может оборваться."
    echo
  fi
fi

read -rp "Применить? Введите YES заглавными: " answer
[[ "$answer" == "YES" ]] || { echo "Отменено."; exit 0; }

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

if [[ -n "${ADMIN_IP:-}" ]]; then
  ufw allow from "$ADMIN_IP" to any port "$SSH_PORT" proto tcp comment 'SSH: админ'
else
  ufw allow "$SSH_PORT"/tcp comment 'SSH'
fi

ufw allow 443/tcp comment 'Клиентский трафик (nginx SNI -> инбаунды)'
ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'Панель Remnawave -> нода'

# Явный запрет бэкенд-портов: страховка на случай, если в конфиг Xray
# когда-нибудь вернётся "listen": "0.0.0.0".
for port in "${PORT_TCP:-4433}" "${PORT_GRPC:-5443}" "${PORT_XHTTP:-8443}"; do
  ufw deny "$port"/tcp comment 'Инбаунд: только через nginx с 127.0.0.1'
done

ufw --force enable

echo
echo "${GREEN}${BOLD}Правила применены.${OFF}"
ufw status numbered

cat <<'NOTE'

Проверьте прямо сейчас, не закрывая эту сессию:
  * откройте вторую SSH-сессию — она должна подключиться;
  * в панели Remnawave нода должна остаться online.

Если используете nftables напрямую, эквивалент такой:

  table inet filter {
    chain input {
      type filter hook input priority 0; policy drop;
      ct state established,related accept
      iif lo accept
      tcp dport 22  ip saddr <ADMIN_IP> accept
      tcp dport 443 accept
      tcp dport <NODE_PORT> ip saddr <PANEL_IP> accept
    }
  }
NOTE
