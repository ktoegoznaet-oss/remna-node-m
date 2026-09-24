#!/usr/bin/env bash
# ============================================================================
#  Генерация боевых конфигов из шаблонов и .env
#
#    nginx/nginx.conf.template        -> nginx/nginx.conf
#    xray/xray-config.json.template   -> xray/xray-config.json
#
#  Один источник правды — .env. Это гарантирует, что маскировочные домены
#  и порты в nginx и в Xray совпадают. Рассинхрон между ними — самая частая
#  причина "всё настроил, но не работает".
#
#  Запуск:  ./scripts/configure.sh
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
die()  { echo "${RED}ОШИБКА:${OFF} $*" >&2; exit 1; }
warn() { echo "${YELLOW}ВНИМАНИЕ:${OFF} $*" >&2; }
ok()   { echo "${GREEN}✓${OFF} $*"; }

# ---------------------------------------------------------------------------
#  1. Читаем .env
# ---------------------------------------------------------------------------
[[ -f .env ]] || die ".env не найден. Выполните: cp .env.example .env и заполните его."

set -a
# shellcheck disable=SC1091
source .env
set +a

# ---------------------------------------------------------------------------
#  2. Проверяем обязательные значения
# ---------------------------------------------------------------------------
REQUIRED=(
  SNI_TCP SNI_GRPC SNI_XHTTP
  PORT_TCP PORT_GRPC PORT_XHTTP
  REALITY_PRIVATE_KEY_TCP REALITY_PRIVATE_KEY_GRPC REALITY_PRIVATE_KEY_XHTTP
  SHORT_ID_TCP SHORT_ID_GRPC SHORT_ID_XHTTP
  XHTTP_PATH GRPC_SERVICE_NAME
)

missing=()
for v in "${REQUIRED[@]}"; do
  [[ -n "${!v:-}" ]] || missing+=("$v")
done
if (( ${#missing[@]} )); then
  die "в .env не заполнены: ${missing[*]}
     Ключи Reality и shortId генерируются скриптом ./scripts/gen-reality-keys.sh"
fi

[[ -n "${SECRET_KEY:-}" ]] || warn "SECRET_KEY пуст — нода не подключится к панели. Конфиги всё равно сгенерирую."

# ---------------------------------------------------------------------------
#  3. Проверяем то, что чаще всего ломается
# ---------------------------------------------------------------------------

# 3.1 Домены-маски должны быть уникальными: nginx различает инбаунды
#     исключительно по SNI, одинаковые значения сделают схему нерабочей
#     (и nginx просто не стартует с "duplicate parameter").
if [[ "$SNI_TCP" == "$SNI_GRPC" || "$SNI_TCP" == "$SNI_XHTTP" || "$SNI_GRPC" == "$SNI_XHTTP" ]]; then
  die "SNI_TCP, SNI_GRPC и SNI_XHTTP должны быть РАЗНЫМИ доменами.
     Сейчас: TCP=$SNI_TCP GRPC=$SNI_GRPC XHTTP=$SNI_XHTTP
     nginx разводит трафик только по имени из TLS ClientHello — при
     совпадении доменов два инбаунда неразличимы."
fi

# 3.2 Домен без схемы, без порта, без markdown-обёрток.
for v in SNI_TCP SNI_GRPC SNI_XHTTP; do
  val="${!v}"
  [[ "$val" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
    || die "$v='$val' — это не голое доменное имя.
     Нужно 'example.com', без https://, без :443, без скобок."
  [[ "$val" == *.* ]] || die "$v='$val' — домен без точки."

  # Зарезервированные имена из RFC 2606/6761 не существуют в интернете.
  # Reality проксирует хендшейк на сайт-цель при КАЖДОМ подключении, поэтому
  # несуществующая цель означает полностью нерабочий инбаунд.
  if [[ "$val" =~ (^|\.)(example\.(com|net|org)|test|invalid|localhost|example)$ ]]; then
    die "$v='$val' — это домен-заглушка, его не существует.
     Reality не сможет выполнить хендшейк с целью, и инбаунд будет мёртв.
     Подберите настоящий домен: ./scripts/check-sni.sh"
  fi
done

# 3.2.1 Мягкая проверка: резолвится ли домен. Сети может не быть — не ошибка.
for v in SNI_TCP SNI_GRPC SNI_XHTTP; do
  val="${!v}"
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$val" >/dev/null 2>&1 || warn "$v='$val' не резолвится с этой машины.
     Если это опечатка — инбаунд работать не будет. Проверка: ./scripts/check-sni.sh $val"
  fi
done

# 3.3 Порты
for v in PORT_TCP PORT_GRPC PORT_XHTTP; do
  val="${!v}"
  [[ "$val" =~ ^[0-9]+$ ]] && (( val > 0 && val < 65536 )) || die "$v='$val' — некорректный порт."
  (( val != 443 )) || die "$v=443 занят nginx. Инбаунды должны слушать другие порты на 127.0.0.1."
done
if [[ "$PORT_TCP" == "$PORT_GRPC" || "$PORT_TCP" == "$PORT_XHTTP" || "$PORT_GRPC" == "$PORT_XHTTP" ]]; then
  die "PORT_TCP, PORT_GRPC, PORT_XHTTP должны быть разными."
fi

# 3.4 shortId — hex чётной длины, до 16 символов
for v in SHORT_ID_TCP SHORT_ID_GRPC SHORT_ID_XHTTP; do
  val="${!v}"
  [[ "$val" =~ ^[0-9a-fA-F]*$ ]] || die "$v='$val' — shortId должен быть hex-строкой."
  (( ${#val} % 2 == 0 )) || die "$v='$val' — длина shortId должна быть чётной."
  (( ${#val} <= 16 ))    || die "$v='$val' — максимум 16 символов."
  (( ${#val} > 0 ))      || warn "$v пуст. Пустой shortId допустим, но снижает стойкость схемы."
done

# 3.5 Путь XHTTP
[[ "$XHTTP_PATH" == /* ]] || die "XHTTP_PATH='$XHTTP_PATH' должен начинаться с /"

ok "значения .env прошли проверку"

# ---------------------------------------------------------------------------
#  4. Подстановка
# ---------------------------------------------------------------------------
# Чистый bash: никаких проблем с экранированием '/', '+' и '=' в ключах,
# в отличие от sed. И никаких внешних зависимостей на сервере.

declare -A VARS=(
  [SNI_TCP]="$SNI_TCP"
  [SNI_GRPC]="$SNI_GRPC"
  [SNI_XHTTP]="$SNI_XHTTP"
  [PORT_TCP]="$PORT_TCP"
  [PORT_GRPC]="$PORT_GRPC"
  [PORT_XHTTP]="$PORT_XHTTP"
  [REALITY_PRIVATE_KEY_TCP]="$REALITY_PRIVATE_KEY_TCP"
  [REALITY_PRIVATE_KEY_GRPC]="$REALITY_PRIVATE_KEY_GRPC"
  [REALITY_PRIVATE_KEY_XHTTP]="$REALITY_PRIVATE_KEY_XHTTP"
  [SHORT_ID_TCP]="$SHORT_ID_TCP"
  [SHORT_ID_GRPC]="$SHORT_ID_GRPC"
  [SHORT_ID_XHTTP]="$SHORT_ID_XHTTP"
  [XHTTP_PATH]="$XHTTP_PATH"
  [GRPC_SERVICE_NAME]="$GRPC_SERVICE_NAME"
)

# Порты в JSON-шаблоне закавычены, чтобы шаблон сам оставался валидным JSON.
# При подстановке кавычки снимаем — порт должен стать числом.
NUMERIC=(PORT_TCP PORT_GRPC PORT_XHTTP)

render() {
  local src="$1" dst="$2" content key
  [[ -f "$src" ]] || die "шаблон не найден: $src"
  content="$(<"$src")"

  for key in "${NUMERIC[@]}"; do
    content="${content//\"__${key}__\"/${VARS[$key]}}"
  done
  for key in "${!VARS[@]}"; do
    content="${content//__${key}__/${VARS[$key]}}"
  done

  if [[ "$content" == *__* && "$content" =~ __[A-Z_]+__ ]]; then
    die "в $dst остались незаполненные плейсхолдеры: $(grep -o '__[A-Z_]*__' <<<"$content" | sort -u | tr '\n' ' ')"
  fi

  printf '%s\n' "$content" > "$dst"
  ok "сгенерирован $dst"
}

render nginx/nginx.conf.template      nginx/nginx.conf
render xray/xray-config.json.template xray/xray-config.json

# ---------------------------------------------------------------------------
#  5. Валидация результата
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  jq empty xray/xray-config.json && ok "xray/xray-config.json — валидный JSON"
elif command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open("xray/xray-config.json"))' && ok "xray/xray-config.json — валидный JSON"
else
  warn "ни jq, ни python3 не найдены — JSON не проверен"
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker run --rm -v "$ROOT/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:stable-alpine nginx -t >/dev/null 2>&1; then
    ok "nginx/nginx.conf — синтаксис корректен"
  else
    warn "nginx -t не прошёл, вывод:"
    docker run --rm -v "$ROOT/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:stable-alpine nginx -t || true
  fi
fi

# ---------------------------------------------------------------------------
#  6. Итог
# ---------------------------------------------------------------------------
cat <<SUMMARY

${BOLD}Карта маршрутизации 443 -> инбаунды${OFF}

  SNI                          порт    инбаунд
  ---------------------------  ------  --------------------------
  $(printf '%-27s' "$SNI_TCP")  $(printf '%-6s' "$PORT_TCP")  VLESS RAW + Reality (Vision)
  $(printf '%-27s' "$SNI_GRPC")  $(printf '%-6s' "$PORT_GRPC")  VLESS gRPC + Reality
  $(printf '%-27s' "$SNI_XHTTP")  $(printf '%-6s' "$PORT_XHTTP")  VLESS XHTTP + Reality

  Любой другой SNI (сканеры, боты, случайные заходы) уходит на порт
  $PORT_TCP и маскируется под настоящий $SNI_TCP.

${BOLD}Дальше:${OFF}
  1. Вставьте xray/xray-config.json в панель Remnawave (см. docs/PANEL-SETUP.md)
  2. docker compose up -d
  3. ./scripts/check.sh

SUMMARY
