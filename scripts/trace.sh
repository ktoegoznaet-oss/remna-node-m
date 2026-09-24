#!/usr/bin/env bash
# ============================================================================
#  Живой просмотр маршрутизации: какой SNI приходит на 443 и в какой бэкенд
#  уходит соединение.
#
#    ./scripts/trace.sh            — показывать до Ctrl+C
#    ./scripts/trace.sh 60         — показывать 60 секунд и выйти
#
#  Временно включает access_log в stream-секции nginx, перечитывает конфиг
#  без разрыва соединений и по выходу возвращает всё как было.
#
#  ВНИМАНИЕ: пока трассировка включена, в лог пишутся IP-адреса клиентов и
#  запрашиваемые ими SNI. Это лог активности пользователей. Включайте на
#  время отладки и не оставляйте работать постоянно.
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
die() { echo "${RED}ОШИБКА:${OFF} $*" >&2; exit 1; }

CONF=nginx/nginx.conf
BACKUP="$CONF.trace-backup"
DURATION="${1:-}"

[[ -f "$CONF" ]] || die "$CONF не найден. Сначала: ./scripts/configure.sh"
docker ps --format '{{.Names}}' | grep -qx remnanode-nginx || die "контейнер remnanode-nginx не запущен."

restore() {
  echo
  echo "Возвращаю конфиг без логирования..."
  if [[ -f "$BACKUP" ]]; then
    # Именно перезапись через '>', а не mv: файл смонтирован в контейнер
    # как bind-mount одного файла, и подмена inode до контейнера не дойдёт.
    cat "$BACKUP" > "$CONF"
    rm -f "$BACKUP"
    docker exec remnanode-nginx nginx -s reload 2>/dev/null
    docker exec remnanode-nginx sh -c 'rm -f /var/log/nginx/stream.log' 2>/dev/null
    echo "${GREEN}✓${OFF} трассировка выключена, лог удалён"
  fi
}
trap restore EXIT INT TERM

cp "$CONF" "$BACKUP"

# Сохраняем inode: bind-mount одного файла привязан именно к нему.
patched="$(sed -E 's|^([[:space:]]*)access_log[[:space:]]+off;|\1access_log /var/log/nginx/stream.log sni_routing;|' "$CONF")"
printf '%s\n' "$patched" > "$CONF"

if ! grep -q 'access_log /var/log/nginx/stream.log' "$CONF"; then
  die "не нашёл строку 'access_log off;' в $CONF — конфиг правили вручную?"
fi

docker exec remnanode-nginx nginx -t >/dev/null 2>&1 || {
  docker exec remnanode-nginx nginx -t
  die "конфиг с логированием не проходит проверку"
}

docker exec remnanode-nginx sh -c ': > /var/log/nginx/stream.log'
docker exec remnanode-nginx nginx -s reload

cat <<INFO

${BOLD}Трассировка включена.${OFF} Подключайтесь клиентом — соединения появятся ниже.

Как читать строку:
  sni="..."          какое имя прислал клиент в TLS ClientHello
  -> 127.0.0.1:ПОРТ  в какой инбаунд nginx направил соединение
  status=200         соединение проксировалось штатно
  status=502         бэкенд отказал: инбаунд не слушает этот порт
  sent=N             байт отдано клиенту, то есть пришло от бэкенда
  recv=N             байт принято от клиента

Два характерных сочетания:
  status=502                  инбаунд не поднят. Конфиг из панели не
                              применён или инбаунд не включён для ноды.
  status=200 и при этом sent=0  инбаунд принял соединение и сразу закрыл,
                              не ответив ни байтом. Типично при рассинхроне
                              PROXY protocol: nginx шлёт заголовок, а Xray
                              его не ждёт.

Если sni пустой или не совпадает ни с одним ключом в map, соединение уходит
в default — и весь трафик оказывается на одном инбаунде.

INFO

if [[ -n "$DURATION" ]]; then
  echo "Показываю $DURATION секунд, затем выключаю."
  echo
  timeout "$DURATION" docker exec remnanode-nginx tail -f /var/log/nginx/stream.log
else
  echo "Ctrl+C — выключить трассировку."
  echo
  docker exec remnanode-nginx tail -f /var/log/nginx/stream.log
fi
