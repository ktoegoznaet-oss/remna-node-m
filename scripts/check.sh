#!/usr/bin/env bash
# ============================================================================
#  Диагностика ноды: что слушает, куда уходит трафик, всё ли закрыто.
#  Запускать на самой ноде: ./scripts/check.sh
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
ok()   { echo "  ${GREEN}✓${OFF} $*"; }
bad()  { echo "  ${RED}✗${OFF} $*"; FAILED=1; }
warn() { echo "  ${YELLOW}!${OFF} $*"; }
head_() { echo; echo "${BOLD}$*${OFF}"; }

FAILED=0

[[ -f .env ]] && { set -a; source .env; set +a; } || { echo "${RED}.env не найден${OFF}"; exit 1; }
: "${PORT_TCP:=4433}" "${PORT_GRPC:=5443}" "${PORT_XHTTP:=8443}" "${NODE_PORT:=2231}"

# ---------------------------------------------------------------------------
head_ "1. Контейнеры"
# ---------------------------------------------------------------------------
if docker ps --format '{{.Names}}' | grep -qx remnanode; then
  ok "remnanode запущен ($(docker inspect -f '{{.State.Status}}, uptime {{.State.StartedAt}}' remnanode))"
else
  bad "remnanode не запущен — docker compose up -d"
fi
if docker ps --format '{{.Names}}' | grep -qx remnanode-nginx; then
  ok "remnanode-nginx запущен"
else
  bad "remnanode-nginx не запущен"
fi

# ---------------------------------------------------------------------------
head_ "2. Прослушиваемые порты"
# ---------------------------------------------------------------------------
LISTEN="$(ss -ltnH 2>/dev/null || netstat -ltn 2>/dev/null)"

if grep -qE '(0\.0\.0\.0|\*|\[::\]):443\b' <<<"$LISTEN"; then
  ok "443 слушается публично (nginx)"
else
  bad "443 никто не слушает — nginx не поднялся"
fi

for pair in "TCP:$PORT_TCP" "gRPC:$PORT_GRPC" "XHTTP:$PORT_XHTTP"; do
  name="${pair%%:*}"; port="${pair##*:}"
  line="$(grep -E "[^0-9]${port}\b" <<<"$LISTEN" | head -1)"
  if [[ -z "$line" ]]; then
    bad "инбаунд $name ($port) не слушается — проверьте конфиг в панели и логи ноды"
  elif grep -qE "127\.0\.0\.1:${port}\b" <<<"$line"; then
    ok "инбаунд $name ($port) слушается только на 127.0.0.1"
  else
    bad "инбаунд $name ($port) торчит НАРУЖУ: $(awk '{print $4}' <<<"$line")
       В конфиге Xray должно быть \"listen\": \"127.0.0.1\".
       Иначе клиент обходит маршрутизацию по SNI и подключается напрямую."
  fi
done

if grep -qE "[^0-9]${NODE_PORT}\b" <<<"$LISTEN"; then
  ok "порт управления $NODE_PORT слушается (панель подключается сюда)"
else
  warn "порт управления $NODE_PORT не слушается — панель не сможет управлять нодой"
fi

# ---------------------------------------------------------------------------
head_ "3. Конфиг nginx"
# ---------------------------------------------------------------------------
if docker exec remnanode-nginx nginx -t >/dev/null 2>&1; then
  ok "синтаксис корректен"
  echo "  Загруженная таблица маршрутизации:"
  docker exec remnanode-nginx nginx -T 2>/dev/null \
    | sed -n '/map \$ssl_preread_server_name/,/}/p' \
    | grep -E '127\.0\.0\.1:' | sed 's/^/    /'
else
  bad "nginx -t не проходит:"
  docker exec remnanode-nginx nginx -t 2>&1 | sed 's/^/    /'
fi

if docker exec remnanode-nginx nginx -T 2>/dev/null | grep -q 'proxy_protocol on'; then
  ok "proxy_protocol включён (Xray получит реальный IP клиента)"
else
  warn "proxy_protocol выключен — в панели все пользователи будут с 127.0.0.1"
fi

# ---------------------------------------------------------------------------
head_ "4. Маршрутизация по SNI (живая проверка)"
# ---------------------------------------------------------------------------
PUBLIC_IP="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
if [[ -z "$PUBLIC_IP" ]]; then
  warn "не определил публичный IP, пропускаю"
else
  echo "  Публичный IP: $PUBLIC_IP"
  for pair in "$SNI_TCP:TCP" "$SNI_GRPC:gRPC" "$SNI_XHTTP:XHTTP"; do
    sni="${pair%%:*}"; name="${pair##*:}"
    out="$(echo | timeout 10 openssl s_client -connect "$PUBLIC_IP:443" \
             -servername "$sni" -brief 2>&1)"
    if grep -q 'Verification: OK\|Verify return code: 0\|Protocol version' <<<"$out"; then
      subj="$(grep -iE 'subject|Hostname' <<<"$out" | head -1 | sed 's/^[[:space:]]*//')"
      ok "$name / $sni — TLS отвечает. ${subj:-сертификат получен}"
    else
      bad "$name / $sni — TLS не установился:
$(sed 's/^/       /' <<<"$out" | head -5)"
    fi
  done
  echo
  echo "  Если при разных SNI возвращаются разные сертификаты — разводка"
  echo "  по инбаундам работает. Одинаковые сертификаты означают, что всё"
  echo "  падает в default (обычно: SNI в map не совпадает с serverNames)."
fi

# ---------------------------------------------------------------------------
head_ "5. Доступность бэкендов снаружи"
# ---------------------------------------------------------------------------
if [[ -n "${PUBLIC_IP:-}" ]]; then
  for port in "$PORT_TCP" "$PORT_GRPC" "$PORT_XHTTP"; do
    if timeout 3 bash -c "</dev/tcp/$PUBLIC_IP/$port" 2>/dev/null; then
      bad "порт $port отвечает на публичном IP — закройте его (listen 127.0.0.1 + фаервол)"
    else
      ok "порт $port снаружи закрыт"
    fi
  done
fi

# ---------------------------------------------------------------------------
head_ "6. Последние ошибки в логах"
# ---------------------------------------------------------------------------
echo "  nginx:"
docker logs --tail 20 remnanode-nginx 2>&1 | grep -iE 'emerg|alert|crit|error' | tail -5 | sed 's/^/    /' \
  || echo "    чисто"
echo "  remnanode:"
docker logs --tail 40 remnanode 2>&1 | grep -iE 'error|failed|panic' | tail -5 | sed 's/^/    /' \
  || echo "    чисто"

# ---------------------------------------------------------------------------
echo
if (( FAILED )); then
  echo "${RED}${BOLD}Есть проблемы — смотрите отметки ✗ выше.${OFF}"
  echo "Разбор типовых случаев: docs/TROUBLESHOOTING.md"
  exit 1
else
  echo "${GREEN}${BOLD}Все проверки пройдены.${OFF}"
fi
