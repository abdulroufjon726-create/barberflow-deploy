#!/usr/bin/env bash
# Render start bosqichi.
#
# Nima qiladi:
#   1. Tailscale'ni `userspace-networking` rejimida ko'taradi (TUN/root kerak emas).
#   2. Auth key bilan tailnet'ga qo'shiladi.
#   3. 127.0.0.1:15432 da TCP->SOCKS5 relay ochadi (tsrelay.py).
#   4. Django migratsiya + demo seed + daphne.
#
# Baza telefonda (tailnet ichida) turadi: DB_HOST/DB_PORT env bilan beriladi.
set -o errexit
set -o pipefail

TS_VERSION="${TS_VERSION:-1.104.7}"
TS_DIR="${TS_DIR:-/tmp/ts}"
SOCKS_PORT="${SOCKS_PORT:-1055}"
RELAY_PORT="${RELAY_PORT:-15432}"
# Django health'dagi telefon-baza probe'i shu port orqali yuradi.
export TS_SOCKS_PORT="${TS_SOCKS_PORT:-$SOCKS_PORT}"
DB_TAILNET_HOST="${DB_TAILNET_HOST:-100.91.30.56}"
DB_TAILNET_PORT="${DB_TAILNET_PORT:-5434}"

# Telefon bazasi rejimi faqat DB_HOST loopback bo'lganda kerak. Asosiy (Render)
# bazada tailscale/relay umuman ko'tarilmaydi: har sovuq startda ular ~70 soniya
# yeb qo'yardi (auth, peer ro'yxati, ping).
PHONE_MODE=0
case "${DB_HOST:-}" in
  127.0.0.1 | localhost) PHONE_MODE=1 ;;
esac

mkdir -p "$TS_DIR"

fetch_tailscale() {
  local arch tgz dir
  arch="$(uname -m)"
  case "$arch" in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
  esac
  tgz="/tmp/tailscale_${TS_VERSION}_${arch}.tgz"
  dir="/tmp/tailscale_${TS_VERSION}_${arch}"
  echo "[start] tailscale ${TS_VERSION} (${arch}) yuklanmoqda"
  curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_${arch}.tgz" -o "$tgz"
  tar -xzf "$tgz" -C /tmp
  cp "$dir/tailscaled" "$dir/tailscale" "$TS_DIR"/
  chmod +x "$TS_DIR/tailscaled" "$TS_DIR/tailscale"
}

if [ "$PHONE_MODE" != "1" ]; then
  echo "[start] telefon bazasi ishlatilmayapti (DB_HOST=${DB_HOST:-belgilanmagan}) - tailscale/relay o'tkazib yuborildi"
else

if [ ! -x "$TS_DIR/tailscaled" ]; then
  fetch_tailscale
fi

if ! "$TS_DIR/tailscale" --socket="$TS_DIR/sock" status >/dev/null 2>&1; then
  echo "[start] tailscaled (userspace) ishga tushirilmoqda"
  "$TS_DIR/tailscaled" \
    --tun=userspace-networking \
    --state="$TS_DIR/state.json" \
    --statedir="$TS_DIR/var" \
    --socket="$TS_DIR/sock" \
    --port=41644 \
    --socks5-server="127.0.0.1:${SOCKS_PORT}" \
    >"$TS_DIR/tailscaled.log" 2>&1 &
  for _ in $(seq 1 60); do
    if "$TS_DIR/tailscale" --socket="$TS_DIR/sock" status >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi

# Tailscale telefon bazasi uchun kerak. U bo'lmasa ham API (asosiy baza — Render)
# ishlashi kerak, shuning uchun kalit yo'qligi deploy'ni to'xtatmaydi.
if [ -n "${TS_AUTHKEY:-}" ]; then
  # Diqqat: tailscale 1.104 `up` da --ephemeral yo'q — uni qo'shilsa up yiqiladi.
  "$TS_DIR/tailscale" --socket="$TS_DIR/sock" up \
    --authkey="$TS_AUTHKEY" \
    --hostname="${TS_HOSTNAME:-render-barberflow}" \
    --accept-dns=false \
    --accept-routes=false ||
    echo "[start] OGOHLANTIRISH: 'tailscale up' xato qaytardi, davom etamiz"
else
  echo "[start] OGOHLANTIRISH: TS_AUTHKEY yo'q — telefon bazasi (tailnet) ishlamaydi, asosiy baza ishlatiladi"
fi

TS_IP=""
for _ in $(seq 1 60); do
  TS_IP="$("$TS_DIR/tailscale" --socket="$TS_DIR/sock" ip -4 2>/dev/null | head -n1 || true)"
  if [ -n "$TS_IP" ]; then
    break
  fi
  sleep 1
done
echo "[start] tailnet IP: ${TS_IP:-topilmadi}"

# DB_TAILNET_HOST IP bo'lmasa (masalan `barber-phone`), tailnet nomidan IP'ni
# aniqlaymiz: telefon qayta qo'shilib IP o'zgarsa ham sozlama ishlayveradi.
case "$DB_TAILNET_HOST" in
  "" | *[!0-9.]*) 
    RESOLVED="$("$TS_DIR/tailscale" --socket="$TS_DIR/sock" ip -4 "$DB_TAILNET_HOST" 2>/dev/null | head -n1 || true)"
    if [ -n "$RESOLVED" ]; then
      echo "[start] ${DB_TAILNET_HOST} -> ${RESOLVED} (tailnet nomidan aniqlandi)"
      DB_TAILNET_HOST="$RESOLVED"
      export DB_TAILNET_HOST
    else
      echo "[start] OGOHLANTIRISH: ${DB_TAILNET_HOST} tailnet'da topilmadi"
    fi
    ;;
esac

# Peer ro'yxati: telefon tuguni onlinemi — logdan darhol ko'rinadi.
TS_STATUS="$("$TS_DIR/tailscale" --socket="$TS_DIR/sock" status 2>&1 | head -n 20 || true)"
printf '%s\n' "$TS_STATUS"
PHONE_LINE="$(printf '%s\n' "$TS_STATUS" | awk -v ip="$DB_TAILNET_HOST" '$1==ip' | head -n1)"
case "$PHONE_LINE" in
  *offline*) PHONE_STATE="offline" ;;
  *active* | *idle*) PHONE_STATE="online" ;;
  "") PHONE_STATE="topilmadi" ;;
  *) PHONE_STATE="noma'lum" ;;
esac
echo "[start] telefon bazasi manzili: ${DB_TAILNET_HOST}:${DB_TAILNET_PORT} (${PHONE_STATE})"
"$TS_DIR/tailscale" --socket="$TS_DIR/sock" ping -c 2 --timeout=5s "$DB_TAILNET_HOST" ||
  echo "[start] OGOHLANTIRISH: ${DB_TAILNET_HOST} ping javob bermadi"

echo "[start] relay ishga tushirilmoqda: 127.0.0.1:${RELAY_PORT} -> ${DB_TAILNET_HOST}:${DB_TAILNET_PORT}"
python tsrelay.py "127.0.0.1:${RELAY_PORT}" "${DB_TAILNET_HOST}:${DB_TAILNET_PORT}" &
RELAY_PID=$!
trap 'kill "$RELAY_PID" 2>/dev/null || true' EXIT

export DB_HOST="${DB_HOST:-127.0.0.1}"
export DB_PORT="${DB_PORT:-$RELAY_PORT}"
export DB_SSLMODE="${DB_SSLMODE:-disable}"

fi  # PHONE_MODE

cd app/backend

# Baza tirikmi? 3 urinish — telefon uyg'onishi sekin bo'lishi mumkin.
db_probe() {
  python - <<'PY'
import os
import sys

params = dict(
    host=os.environ.get("DB_HOST", "127.0.0.1"),
    port=int(os.environ.get("DB_PORT", "15432")),
    dbname=os.environ.get("DB_NAME", "barberflow"),
    user=os.environ.get("DB_USER", "barber"),
    password=os.environ.get("DB_PASSWORD", ""),
    sslmode=os.environ.get("DB_SSLMODE", "disable"),
    connect_timeout=15,
)

try:
    try:
        import psycopg as driver
    except ImportError:
        import psycopg2 as driver
    conn = driver.connect(**params)
    cur = conn.cursor()
    cur.execute("select version()")
    print("[start] PG ulanish OK:", cur.fetchone()[0][:70])
    conn.close()
except Exception as exc:  # noqa: BLE001 - diagnostika uchun
    print("[start] PG ulanish XATO:", repr(exc))
    sys.exit(1)
PY
}

DB_OK=0
for attempt in 1 2 3; do
  if db_probe; then
    DB_OK=1
    break
  fi
  if [ "$attempt" != "3" ]; then
    echo "[start] baza javob bermadi (${attempt}/3), 8s kutamiz"
    sleep 8
  fi
done

# Telefon bazasi rejimida (DB_HOST=127.0.0.1 -> relay) baza javob bermasa, API
# yiqilib qolmasin: DB_* olib tashlanadi va Django `DATABASE_URL` (Render PG)
# ga qaytadi. Telefon keyin qaytsa — env'dagi manzil o'z-o'zidan ishlatiladi.
if [ "$DB_OK" != "1" ] && [ "$PHONE_MODE" = "1" ] && [ -n "${DATABASE_URL:-}" ]; then
  echo "[start] OGOHLANTIRISH: telefon bazasi ishlamayapti — asosiy (Render) bazaga avtomatik qaytildi"
  unset DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_SSLMODE
  if db_probe; then
    DB_OK=1
  else
    echo "[start] XATO: asosiy baza ham javob bermadi"
  fi
fi

migrated=0
for attempt in 1 2 3 4 5; do
  if python manage.py migrate --noinput; then
    migrated=1
    break
  fi
  echo "[start] migrate ${attempt}-urinishda bajarilmadi, 10s kutamiz"
  sleep 10
done
if [ "$migrated" != "1" ]; then
  echo "[start] DIQQAT: migrate bajarilmadi"
fi

python manage.py seed_demo || echo "[start] seed_demo xato qaytardi"

# Self keep-alive: Render bepul rejimi 15 daqiqa kiruvchi trafik bo'lmasa konteyner
# uxlaydi (keyingi so'rov ~1 daqiqa kutadi). Har 10 daqiqada o'z health'imizni
# urib turamiz — shunda API uxlab qolmaydi. GitHub cron'iga bog'liq emas.
KEEPALIVE_URL="${KEEPALIVE_URL:-}"
if [ -n "$KEEPALIVE_URL" ]; then
  KEEPALIVE_INTERVAL="${KEEPALIVE_INTERVAL:-600}"
  echo "[start] keep-alive: har ${KEEPALIVE_INTERVAL}s -> ${KEEPALIVE_URL%/}/api/health/"
  (
    failures=0
    while sleep "$KEEPALIVE_INTERVAL"; do
      if curl -fsS -m 30 -o /dev/null "${KEEPALIVE_URL%/}/api/health/" 2>/dev/null; then
        failures=0
      else
        failures=$((failures + 1))
        if [ "$failures" -ge 3 ]; then
          echo "[keepalive] OGOHLANTIRISH: health javob bermayapti (${failures} urinish)"
        fi
      fi
    done
  ) &
else
  echo "[start] keep-alive o'chirilgan (KEEPALIVE_URL yo'q) — bepul rejimda servis uxlab qolishi mumkin"
fi

# Telegram bot (long polling) va eslatma yuboruvchi — daphne bilan birga fonda.
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  echo "[start] Telegram bot va notifier ishga tushirilmoqda"
  # Chiqish konteyner logiga ketadi — Render'da ko'rinadi.
  nohup python -u manage.py run_bot 2>&1 &
  nohup python -u manage.py run_notifier 2>&1 &
fi

exec daphne -b 0.0.0.0 -p "${PORT:-8000}" config.asgi:application
