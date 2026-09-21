#!/usr/bin/env bash
# ============================================================================
#  Генерация ключевых пар Reality (x25519) и shortId для трёх инбаундов.
#
#    ./scripts/gen-reality-keys.sh           — только показать
#    ./scripts/gen-reality-keys.sh --write   — сразу записать приватные
#                                              ключи и shortId в .env
#
#  ПРИВАТНЫЙ ключ остаётся на сервере (в .env и конфиге Xray).
#  ПУБЛИЧНЫЙ ключ вводится в панели Remnawave в разделе Hosts — он уходит
#  клиенту в подписке. Выпишите публичные ключи, скрипт их не хранит.
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
die() { echo "${RED}ОШИБКА:${OFF} $*" >&2; exit 1; }

WRITE=0
[[ "${1:-}" == "--write" ]] && WRITE=1

command -v docker >/dev/null 2>&1 || die "нужен docker."
docker info >/dev/null 2>&1 || die "демон docker не отвечает. Запустите: systemctl start docker"

# Предпочитаем уже работающую ноду — в ней тот же xray, что будет исполнять
# конфиг. Если она ещё не поднята, берём официальный образ xray-core.
if docker ps --format '{{.Names}}' | grep -qx remnanode; then
  run_xray() { docker exec remnanode xray "$@"; }
  echo "Использую xray из работающего контейнера remnanode."
else
  run_xray() { docker run --rm ghcr.io/xtls/xray-core:latest "$@"; }
  echo "Контейнер remnanode не запущен, использую образ ghcr.io/xtls/xray-core."
fi

gen_short_id() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8
  else
    head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

declare -A PRIV PUB SHORT
NAMES=(TCP GRPC XHTTP)

for n in "${NAMES[@]}"; do
  raw="$(run_xray x25519 2>&1)" || die "не удалось выполнить 'xray x25519':
$raw"

  # Формат вывода менялся между версиями Xray:
  #   "Private key:" / "Public key:"   — старые сборки
  #   "PrivateKey:"  / "Password:"     — сборки 25.x
  priv="$(grep -iE '^(private ?key)' <<<"$raw" | head -1 | awk '{print $NF}')"
  pub="$(grep -iE '^(public ?key|password)' <<<"$raw" | head -1 | awk '{print $NF}')"

  [[ -n "$priv" && -n "$pub" ]] || die "не разобрал вывод xray x25519:
$raw"

  PRIV[$n]="$priv"
  PUB[$n]="$pub"
  SHORT[$n]="$(gen_short_id)"
done

echo
echo "${BOLD}Сгенерированные параметры${OFF}"
for n in "${NAMES[@]}"; do
  echo
  echo "  ${BOLD}$n${OFF}"
  echo "    приватный ключ (в .env, остаётся на сервере): ${PRIV[$n]}"
  echo "    ${GREEN}публичный ключ (в панель, раздел Hosts): ${PUB[$n]}${OFF}"
  echo "    shortId (и в .env, и в панель):               ${SHORT[$n]}"
done
echo

if (( WRITE )); then
  [[ -f .env ]] || die ".env не найден. Сначала: cp .env.example .env"
  cp .env ".env.bak.$(date +%Y%m%d-%H%M%S)"

  python3 - <<PY
import re, pathlib
p = pathlib.Path('.env'); t = p.read_text()
vals = {
  'REALITY_PRIVATE_KEY_TCP':   '${PRIV[TCP]}',
  'REALITY_PRIVATE_KEY_GRPC':  '${PRIV[GRPC]}',
  'REALITY_PRIVATE_KEY_XHTTP': '${PRIV[XHTTP]}',
  'SHORT_ID_TCP':              '${SHORT[TCP]}',
  'SHORT_ID_GRPC':             '${SHORT[GRPC]}',
  'SHORT_ID_XHTTP':            '${SHORT[XHTTP]}',
}
for k, v in vals.items():
    t, n = re.subn(rf'^{k}=.*$', f'{k}={v}', t, flags=re.M)
    if not n:
        t += f'\n{k}={v}\n'
p.write_text(t)
PY
  echo "${GREEN}✓${OFF} приватные ключи и shortId записаны в .env (резервная копия рядом)"
  echo "  Дальше: ./scripts/configure.sh"
else
  echo "${YELLOW}Значения нигде не сохранены.${OFF} Перенесите их в .env вручную"
  echo "или перезапустите с ключом --write."
fi

echo
echo "${YELLOW}Публичные ключи больше нигде не хранятся — выпишите их сейчас.${OFF}"
