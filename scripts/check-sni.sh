#!/usr/bin/env bash
# ============================================================================
#  Проверка доменов-кандидатов на роль маскировочного сайта Reality.
#
#    ./scripts/check-sni.sh                        — проверить список по умолчанию
#    ./scripts/check-sni.sh example.com foo.org    — проверить свои варианты
#
#  Запускать НА НОДЕ. Доступность, задержка и блокировки зависят от того,
#  откуда идёт запрос, — результат с другой машины ничего не говорит.
#
#  Что проверяется и почему:
#    TLS 1.3   — обязателен, без него Reality не работает;
#    X25519    — обязателен, это группа обмена ключами, на которой
#                строится маскировка;
#    ALPN h2   — обязателен для XHTTP (режим stream-one), желателен всегда.
#                ALPN в Reality наследуется от сайта-цели: если он не умеет
#                h2, клиент XHTTP скатится в медленный packet-up или не
#                подключится вовсе;
#    CDN       — Cloudflare, Akamai, Fastly и подобные не годятся: общие
#                сертификаты и плавающие адреса ломают маскировку;
#    редирект  — сайт не должен уводить на другой домен;
#    RTT       — Reality проксирует хендшейк на сайт-цель, и его задержка
#                добавляется к установке КАЖДОГО соединения. Чем ближе
#                цель к ноде, тем быстрее подключаются клиенты.
# ============================================================================
set -uo pipefail

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; OFF=$'\033[0m'

DEFAULTS=(
  www.lovelive-anime.jp
  dl.google.com
  swdist.apple.com
  gateway.icloud.com
  download-installer.cdn.mozilla.net
  www.samsung.com
  www.nvidia.com
  www.asus.com
)

CANDIDATES=("$@")
(( ${#CANDIDATES[@]} )) || CANDIDATES=("${DEFAULTS[@]}")

command -v openssl >/dev/null 2>&1 || { echo "${RED}нужен openssl${OFF}"; exit 1; }

check() {
  local d="$1" verdict=() score=0

  local t0 t1 rtt out
  t0=$(date +%s%N)
  out="$(timeout 10 openssl s_client -connect "$d:443" -servername "$d" \
          -tls1_3 -alpn h2 -brief </dev/null 2>&1)"
  t1=$(date +%s%N)
  rtt=$(( (t1 - t0) / 1000000 ))

  if ! grep -q 'TLSv1.3' <<<"$out"; then
    printf '%-38s %s\n' "$d" "${RED}TLS 1.3 не согласован — не годится${OFF}"
    return
  fi
  (( score++ ))

  # Группа обмена ключами
  local group
  group="$(grep -oP 'Negotiated TLS1.3 group:\s*\K\S+' <<<"$out" | head -1)"
  [[ -z "$group" ]] && group="$(grep -oP 'Server Temp Key:\s*\K\S+' <<<"$out" | head -1)"
  if grep -qiE 'x25519' <<<"${group:-}"; then
    (( score++ ))
  else
    verdict+=("${YELLOW}группа ${group:-неизвестна}, нужен X25519${OFF}")
  fi

  # ALPN
  local alpn
  alpn="$(timeout 10 openssl s_client -connect "$d:443" -servername "$d" \
            -alpn h2,http/1.1 </dev/null 2>&1 | grep -oP 'ALPN protocol:\s*\K\S+' | head -1)"
  if [[ "$alpn" == "h2" ]]; then
    (( score++ ))
  else
    verdict+=("${RED}нет h2 (${alpn:-пусто}) — XHTTP работать не будет${OFF}")
  fi

  # Кто выдал сертификат: отсекаем CDN
  local issuer
  issuer="$(grep -oP '^\s*issuer=.*' <<<"$out" | head -1)"
  [[ -z "$issuer" ]] && issuer="$(timeout 10 openssl s_client -connect "$d:443" \
      -servername "$d" </dev/null 2>&1 | grep -oP '^issuer=\K.*' | head -1)"
  if grep -qiE 'cloudflare|akamai|fastly|amazon|google trust' <<<"${issuer:-}"; then
    verdict+=("${YELLOW}похоже на CDN: ${issuer:0:40}${OFF}")
  else
    (( score++ ))
  fi

  # Редирект на чужой домен
  if command -v curl >/dev/null 2>&1; then
    local loc
    loc="$(timeout 8 curl -sI "https://$d/" 2>/dev/null \
            | grep -i '^location:' | tr -d '\r' | awk '{print $2}')"
    if [[ -n "$loc" && "$loc" != *"$d"* ]]; then
      verdict+=("${YELLOW}редирект на $loc${OFF}")
    fi
  fi

  # RTT
  local rtt_note=""
  if   (( rtt < 80  )); then rtt_note="${GREEN}${rtt} мс${OFF}"; (( score++ ))
  elif (( rtt < 200 )); then rtt_note="${YELLOW}${rtt} мс${OFF}"
  else                       rtt_note="${RED}${rtt} мс — далеко${OFF}"
  fi

  local mark
  if (( score >= 5 )); then mark="${GREEN}${BOLD}годится${OFF}"
  elif (( score >= 4 )); then mark="${YELLOW}приемлемо${OFF}"
  else mark="${RED}не годится${OFF}"
  fi

  # Выравниваем только имя домена: цветовые коды ломают ширину колонок.
  printf '%-38s %s, хендшейк %s%s\n' \
    "$d" "$mark" "$rtt_note" "${verdict[*]:+  —  ${verdict[*]}}"
}

echo
echo "${BOLD}Проверка кандидатов на маскировочный домен${OFF}"
echo "Запускать с той машины, где стоит нода."
echo
printf '%-38s %s\n' "ДОМЕН" "ВЕРДИКТ, ЗАДЕРЖКА ХЕНДШЕЙКА, ЗАМЕЧАНИЯ"
printf '%s\n' "$(printf '%.0s-' {1..78})"

for d in "${CANDIDATES[@]}"; do check "$d"; done

cat <<'NOTE'

Вердикт складывается из: TLS 1.3, X25519, ALPN h2, отсутствие CDN, близость.

Выбрав домен, пропишите его в .env и пересоберите конфиги:

  nano .env                 # SNI_XHTTP=выбранный.домен
  ./scripts/configure.sh
  # вставить xray/xray-config.json в панель, поправить SNI в хосте
  docker compose restart nginx
  docker compose restart remnanode

target и serverNames должны указывать на один и тот же домен — configure.sh
делает это автоматически из одного значения.
NOTE
