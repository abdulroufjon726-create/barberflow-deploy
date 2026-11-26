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
DB_TAILNET_HOST="${DB_TAILNET_HOST:-100.91.30.56}"
DB_TAILNET_PORT="${DB_TAILNET_PORT:-5434}"

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

: "${TS_AUTHKEY:?TS_AUTHKEY env var kerak (Render -> Environment)}"
"$TS_DIR/tailscale" --socket="$TS_DIR/sock" up \
  --authkey="$TS_AUTHKEY" \
  --hostname="${TS_HOSTNAME:-render-barberflow}" \
  --accept-dns=false \
  --accept-routes=false ||
  echo "[start] OGOHLANTIRISH: 'tailscale up' xato qaytardi, davom etamiz"

TS_IP=""
for _ in $(seq 1 60); do
  TS_IP="$("$TS_DIR/tailscale" --socket="$TS_DIR/sock" ip -4 2>/dev/null | head -n1 || true)"
  if [ -n "$TS_IP" ]; then
    break
  fi
  sleep 1
done
echo "[start] tailnet IP: ${TS_IP:-topilmadi}"
"$TS_DIR/tailscale" --socket="$TS_DIR/sock" status || true
"$TS_DIR/tailscale" --socket="$TS_DIR/sock" ping -c 2 --timeout=5s "$DB_TAILNET_HOST" ||
  echo "[start] OGOHLANTIRISH: ${DB_TAILNET_HOST} ping javob bermadi"

echo "[start] relay ishga tushirilmoqda: 127.0.0.1:${RELAY_PORT} -> ${DB_TAILNET_HOST}:${DB_TAILNET_PORT}"
python tsrelay.py "127.0.0.1:${RELAY_PORT}" "${DB_TAILNET_HOST}:${DB_TAILNET_PORT}" &
RELAY_PID=$!
export RELAY_PID
trap 'kill "$RELAY_PID" 2>/dev/null || true' EXIT

export DB_HOST="${DB_HOST:-127.0.0.1}"
export DB_PORT="${DB_PORT:-$RELAY_PORT}"
export DB_SSLMODE="${DB_SSLMODE:-disable}"

cd app/backend

python - <<'PY' || true
import os

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
PY

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

exec daphne -b 0.0.0.0 -p "${PORT:-8000}" config.asgi:application
