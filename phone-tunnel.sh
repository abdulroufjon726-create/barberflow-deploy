#!/data/data/com.termux/files/usr/bin/bash
# phone-tunnel.sh — telefonni tailnet'da ushlab turadigan kuzatuvchi (root kerak emas).
#
# Nima qiladi:
#   * tailscaled'ni userspace rejimda ko'taradi (TUN/root kerak emas);
#   * jarayon o'chib qolsa qayta ko'taradi, tailnet'dan chiqib ketsa qayta qo'shadi;
#   * `serve --tcp=5434 -> 127.0.0.1:5434` ni har safar tiklaydi va boshqa
#     (keraksiz funnel/https/eski port) yo'llarini o'chiradi;
#   * PostgreSQL o'chib qolgan bo'lsa o'zi qayta ko'taradi (BFP_PG_AUTOSTART=1);
#   * har 5 daqiqada API health'ni uradi (Render uxlab qolmasin) va
#     tailscale ping bilan tailnet aloqasini tekshiradi;
#   * hammasini ~/.ts2/tunnel.log ga yozadi.
#
# Telefon uxlab qolmasligi uchun: termux-wake-lock (skript har sikl'da qayta
# oladi), Termux:Boot o'rnatilgan bo'lsin va Android sozlamalarida Termux
# batareya cheklovisiz (Unrestricted) bo'lsin.
#
# Termux'da bir marta (keyin hech narsa kerak emas — Termux:Boot o'zi ishga tushiradi):
#   bash /sdcard/Android/data/com.termux/files/bfp-install/phone-tunnel.sh --install
#
# Boshqa rejimlar:
#   bash ~/bfp-tunnel.sh            # kuzatuvchi (boot'dan keyin o'zi ishga tushadi)
#   bash ~/bfp-tunnel.sh --repair   # baza + tunnel + serve'ni bir buyruqda tiklaydi
#   bash ~/bfp-tunnel.sh --status   # hozirgi holat
set -u

NODE="${BFP_NODE:-barber-phone}"
TCP_PORT="${BFP_TCP_PORT:-5434}"
SERVE_PORT="${BFP_SERVE_PORT:-5434}"
TS_PORT="${BFP_TS_PORT:-41643}"
TS_VER="${BFP_TS_VER:-1.104.7}"
TS_DIR="${BFP_TS_DIR:-$HOME/.ts2}"
BUNDLE="${BFP_BUNDLE:-/sdcard/Android/data/com.termux/files/bfp-install}"
SELF="$HOME/bfp-tunnel.sh"
API_URL="${BFP_API_URL:-https://barberflow-api-8ptv.onrender.com}"
# Render bepul rejimi 15 daqiqa harakatsizlikdan keyin uxlaydi: 5 daqiqada bir
# urish yetarli (vaqtinchalik kechikishlarga ham joy qoldiradi).
KEEPALIVE="${BFP_KEEPALIVE_SECS:-300}"

SOCK="${BFP_SOCK:-$TS_DIR/sock}"
# PostgreSQL o'chib qolsa qayta ko'tarish (0 qilsa o'chiriladi).
PG_AUTOSTART="${BFP_PG_AUTOSTART:-1}"
PG_DATA="${BFP_PG_DATA:-${PREFIX:-/data/data/com.termux/files/usr}/var/lib/postgresql-barberflow}"
STATE="$TS_DIR/state"
STATEDIR="$TS_DIR/var"
LOG="$TS_DIR/tunnel.log"
API_STATE="$TS_DIR/api-health.txt"
PING_STATE="$TS_DIR/ping.txt"
PIDFILE="$TS_DIR/supervisor.pid"
KEYFILE="$TS_DIR/authkey"
TS_BIN="$TS_DIR/bin/tailscale"
BFP_BRIDGE="${BFP_BRIDGE:-0}"

mkdir -p "$TS_DIR" "$TS_DIR/bin" 2>/dev/null
chmod 700 "$TS_DIR" 2>/dev/null

log() {
  [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 262144 ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
  printf '%s\n' "$*"
}

ts() { "$TS_BIN" --socket="$SOCK" "$@" 2>/dev/null; }

backend_state() {
  ts status --json | tr -d ' \n' | sed -n 's/.*"BackendState":"\([^"]*\)".*/\1/p'
}

daemon_up() {
  "$TS_BIN" --socket="$SOCK" status >/dev/null 2>&1
}

# --- binarlar -------------------------------------------------------------
ensure_bin() {
  if [ -x "$TS_DIR/bin/tailscaled" ] && [ -x "$TS_DIR/bin/tailscale" ]; then
    return 0
  fi
  case "$(uname -m)" in
    aarch64 | arm64) TARCH=arm64 ;;
    armv7l | armv8l) TARCH=arm ;;
    x86_64) TARCH=amd64 ;;
    *) TARCH=arm64 ;;
  esac
  log "tailscale ${TS_VER} yuklanmoqda (${TARCH})"
  if curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TS_VER}_${TARCH}.tgz" \
    -o "$TS_DIR/pkg.tgz" 2>/dev/null &&
    tar xzf "$TS_DIR/pkg.tgz" -C "$TS_DIR" 2>/dev/null; then
    SRC="$(ls -d "$TS_DIR"/tailscale_"${TS_VER}"_"$TARCH" 2>/dev/null | head -1)"
    if [ -n "$SRC" ]; then
      cp "$SRC/tailscale" "$SRC/tailscaled" "$TS_DIR/bin/" || return 1
      chmod 700 "$TS_DIR/bin/tailscale" "$TS_DIR/bin/tailscaled"
      rm -rf "$SRC" "$TS_DIR/pkg.tgz"
      return 0
    fi
  fi
  rm -f "$TS_DIR/pkg.tgz"
  if command -v tailscaled >/dev/null 2>&1 && command -v tailscale >/dev/null 2>&1; then
    log "OGOHLANTIRISH: yuklab bo'lmadi — \$PREFIX/bin'dagi tailscale ishlatiladi"
    ln -sf "$(command -v tailscale)" "$TS_DIR/bin/tailscale"
    ln -sf "$(command -v tailscaled)" "$TS_DIR/bin/tailscaled"
    return 0
  fi
  log "XATO: tailscale binarlari topilmadi (internetni tekshiring)"
  return 1
}

# --- PostgreSQL -----------------------------------------------------------
# Telefon ekrani o'chganda yoki Termux qayta ochilganda PostgreSQL to'xtab
# qolishi mumkin. Har sikl'da portni tekshiramiz va kerak bo'lsa ko'taramiz.
pg_listening() {
  (exec 3<>/dev/tcp/127.0.0.1/"$TCP_PORT") 2>/dev/null
}

# postmaster.pid faqat jarayon tirik bo'lsa haqiqiy lock. Telefon qayta yonganda
# yoki Termux o'ldirilganda fayl qolib ketadi va `pg_ctl start` yiqiladi —
# shuning uchun o'lik lock'ni o'chirib tashlaymiz.
pg_pid_alive() {
  [ -f "$PG_DATA/postmaster.pid" ] || return 1
  PGPID="$(head -1 "$PG_DATA/postmaster.pid" 2>/dev/null)"
  [ -n "$PGPID" ] || return 1
  kill -0 "$PGPID" 2>/dev/null
}

pg_cleanup_stale() {
  [ -f "$PG_DATA/postmaster.pid" ] || return 0
  pg_pid_alive && return 0
  log "eski postmaster.pid (jarayon yo'q) tozalanmoqda"
  rm -f "$PG_DATA/postmaster.pid"
}

pg_ready() {
  command -v pg_isready >/dev/null 2>&1 || return 0
  pg_isready -h 127.0.0.1 -p "$TCP_PORT" -q 2>/dev/null
}

ensure_pg() {
  [ "$PG_AUTOSTART" = "1" ] || return 0
  command -v pg_ctl >/dev/null 2>&1 || return 0
  if [ ! -d "$PG_DATA" ]; then
    log "OGOHLANTIRISH: PostgreSQL data katalogi yo'q: $PG_DATA"
    return 0
  fi
  pg_listening && pg_ready && return 0
  pg_cleanup_stale
  log "PostgreSQL ko'tarilmoqda (data: $PG_DATA, port: $TCP_PORT)"
  if pg_ctl -D "$PG_DATA" -l "$PG_DATA/server.log" -o "-p $TCP_PORT" -w -t 60 start >/dev/null 2>&1; then
    log "PostgreSQL tayyor (pg_isready: $(pg_ready && echo ok || echo '?'))"
  else
    log "OGOHLANTIRISH: PostgreSQL ko'tarilmadi — server.log oxiri:"
    tail -3 "$PG_DATA/server.log" 2>/dev/null | while read -r line; do log "  $line"; done
  fi
}

# --- daemon ---------------------------------------------------------------
start_daemon() {
  # Termux uid'ida qolib ketgan eski nusxalarni to'xtatamiz (o'zimiznikidan tashqari).
  # Boshqa uid'lar bu yerga ko'rinmaydi, shuning uchun faqat o'zimizniki o'chadi.
  if command -v pgrep >/dev/null 2>&1; then
    for p in $(pgrep -x tailscaled 2>/dev/null); do
      [ "$p" = "${DAEMON_PID:-}" ] && continue
      kill "$p" 2>/dev/null && log "eski tailscaled to'xtatildi (pid $p)"
    done
  fi
  log "tailscaled ko'tarilmoqda (userspace, port $TS_PORT)"
  (
    umask 077
    nohup "$TS_DIR/bin/tailscaled" \
      --tun=userspace-networking \
      --state="$STATE" \
      --statedir="$STATEDIR" \
      --socket="$SOCK" \
      --port="$TS_PORT" \
      >>"$LOG" 2>&1 &
    echo $! >"$TS_DIR/daemon.pid"
  )
  DAEMON_PID="$(cat "$TS_DIR/daemon.pid" 2>/dev/null)"
  i=0
  while [ "$i" -lt 30 ]; do
    i=$((i + 1))
    daemon_up && {
      log "tailscaled tayyor (pid $DAEMON_PID)"
      return 0
    }
    sleep 1
  done
  log "OGOHLANTIRISH: tailscaled 30s ichida javob bermadi"
  return 1
}

ensure_up() {
  typeset bs
  bs="$(backend_state)"
  case "$bs" in
    Running | Starting | NoState) return 0 ;;
  esac
  if [ -s "$KEYFILE" ]; then
    log "tailnet'ga qayta qo'shilmoqda (BackendState=${bs:-?})"
    ts up --auth-key="$(tr -d ' \t\r\n' <"$KEYFILE")" \
      --hostname="$NODE" --accept-dns=false >/dev/null 2>&1 ||
      log "OGOHLANTIRISH: 'tailscale up' xato qaytardi"
  else
    log "BackendState=${bs:-?} — auth kaliti yo'q, 'tailscale up' chiqishi:"
    ts up --hostname="$NODE" --accept-dns=false | tail -5 >>"$LOG" 2>/dev/null
  fi
  sleep 3
}

serve_routes() {
  ts serve status 2>/dev/null | grep -E '^(tcp|https)://' || true
}

# Faqat bitta yo'l kerak: tcp/5434 -> 127.0.0.1:5434.
# Funnel, https yoki boshqa portdagi qoldiqlar avtomatik tozalanadi.
ensure_serve() {
  [ "$(backend_state)" = "Running" ] || return 0
  ROUTES="$(serve_routes)"
  EXTRA="$(printf '%s\n' "$ROUTES" | grep -Ev "^tcp://[^ ]*:$SERVE_PORT\$" || true)"
  if [ -n "$EXTRA" ]; then
    log "keraksiz serve yo'llari tozalanmoqda: $(printf '%s' "$EXTRA" | tr '\n' ' ')"
    ts serve reset >/dev/null 2>&1
    ROUTES=""
  fi
  if printf '%s\n' "$ROUTES" | grep -q ":$SERVE_PORT\$"; then
    return 0
  fi
  log "serve tiklanmoqda: tcp/$SERVE_PORT -> 127.0.0.1:$TCP_PORT"
  ts serve --bg --tcp="$SERVE_PORT" "tcp://127.0.0.1:$TCP_PORT" >/dev/null 2>&1
  sleep 2
  serve_routes | grep -q ":$SERVE_PORT\$" ||
    log "OGOHLANTIRISH: serve ochilmadi (tailscale serve status ni tekshiring)"
}

# Render uxlab qolmasligi uchun API'ni uradi (Render free rejimi 15 daqiqada uxlaydi).
# Health bazani ham tekshiradi: 503 bo'lsa baza/tunnel muammosi bor.
keep_api_awake() {
  command -v curl >/dev/null 2>&1 || return 0
  # Uxlayotgan servis birinchi so'rovda 60s gacha javob berishi mumkin.
  CODE="$(curl -fsS -m 75 --retry 2 --retry-delay 5 -o /dev/null -w '%{http_code}' \
    "$API_URL/api/health/" 2>/dev/null || true)"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${CODE:-000}" >"$API_STATE" 2>/dev/null
  if [ "${CODE:-000}" != "200" ]; then
    API_FAILS=$((API_FAILS + 1))
    log "OGOHLANTIRISH: API health ${CODE:-000} ($API_URL) — ketma-ket $API_FAILS marta"
  elif [ "${API_FAILS:-0}" -gt 0 ]; then
    log "API health tiklandi (oldin ${API_FAILS} marta javob bermagan)"
    API_FAILS=0
  fi
}

# Tailnet aloqasini ping bilan tekshiradi (birinchi peer'ga).
tailnet_ping() {
  [ "$(backend_state)" = "Running" ] || return 0
  PEER="$(ts status --json 2>/dev/null | tr -d ' \n' \
    | sed -n 's/.*"TailscaleIPs":\["\([0-9.]*\)".*/\1/p' | head -1)"
  [ -n "$PEER" ] || return 0
  if ts ping -c 1 --timeout=5s "$PEER" >/dev/null 2>&1; then
    printf '%s ok %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$PEER" >"$PING_STATE" 2>/dev/null
  else
    printf '%s xato %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$PEER" >"$PING_STATE" 2>/dev/null
    log "OGOHLANTIRISH: tailscale ping $PEER javob bermadi"
  fi
}

# --- o'rnatish ------------------------------------------------------------
install_self() {
  if [ "$(readlink -f "$0" 2>/dev/null)" != "$(readlink -f "$SELF" 2>/dev/null)" ]; then
    cp "$0" "$SELF" && chmod 700 "$SELF" || return 1
  fi
  log "kuzatuvchi: $SELF"
}

install_boot() {
  mkdir -p "$HOME/.termux/boot" || return 1
  cat >"$HOME/.termux/boot/barberflow-tailscale.sh" <<'BOOT'
#!/data/data/com.termux/files/usr/bin/bash
# Telefon qayta yonganda bazani va tunnelni o'zi ko'taradi (Termux:Boot).
# Baza va serve yo'li kuzatuvchining o'zida tiklanadi (ensure_pg / ensure_serve).
termux-wake-lock 2>/dev/null || true
pgrep -f 'bfp-tunnel[.]sh$' >/dev/null 2>&1 && exit 0
nohup bash "$HOME/bfp-tunnel.sh" >/dev/null 2>&1 &
BOOT
  chmod 700 "$HOME/.termux/boot/barberflow-tailscale.sh"
  log "boot hook: ~/.termux/boot/barberflow-tailscale.sh"
}

install_bashrc() {
  # Zaxira yo'l: Termux qo'lda ochilsa ham kuzatuvchi ko'tariladi.
  grep -q 'bfp-tunnel-autostart' "$HOME/.bashrc" 2>/dev/null && return 0
  cat >>"$HOME/.bashrc" <<'RC'

# bfp-tunnel-autostart
pgrep -f 'bfp-tunnel[.]sh$' >/dev/null 2>&1 || nohup bash "$HOME/bfp-tunnel.sh" >/dev/null 2>&1 &
RC
  log "Termux ochilganda ham avtomatik ko'tariladi (.bashrc)"
}

start_supervisor() {
  if pgrep -f 'bfp-tunnel[.]sh$' >/dev/null 2>&1; then
    log "kuzatuvchi allaqachon ishlayapti"
    return 0
  fi
  nohup bash "$SELF" >/dev/null 2>&1 &
  log "kuzatuvchi ishga tushirildi"
}

show_status() {
  echo "--- bfp-tunnel ---"
  daemon_up && echo "daemon: ishlayapti" || echo "daemon: yo'q"
  echo "backend: $(backend_state)"
  echo "tailnet IP: $(ts ip -4 | head -1)"
  echo "baza 127.0.0.1:$TCP_PORT: $(pg_listening && echo ochiq || echo yopiq)"
  command -v pg_isready >/dev/null 2>&1 &&
    echo "pg_isready: $(pg_ready && echo ok || echo xato)"
  echo "serve yo'llari:"
  serve_routes
  [ -f "$API_STATE" ] && echo "API health: $(cat "$API_STATE")"
  [ -f "$PING_STATE" ] && echo "tailscale ping: $(cat "$PING_STATE")"
  echo "--- log (oxirgi 8 qator) ---"
  tail -8 "$LOG" 2>/dev/null
}

do_install() {
  log "=== o'rnatish boshlandi ==="
  for c in curl tar pgrep; do
    command -v "$c" >/dev/null 2>&1 && continue
    log "$c o'rnatilmoqda (pkg)"
    pkg install -y $([ "$c" = "pgrep" ] && echo procps || echo "$c") >/dev/null 2>&1
  done
  install_self || log "XATO: skriptni nusxalab bo'lmadi"
  ensure_bin || log "XATO: binarlar tayyor emas"

  # Keraksiz eski yo'llar: bore tunneli, funnel skripti, eski kuzatuvchilar.
  if command -v pkill >/dev/null 2>&1; then
    pkill -x bore 2>/dev/null && log "eski bore tunneli to'xtatildi"
    pkill -f 'barberflow-tunnel[.]sh' 2>/dev/null && log "eski bore kuzatuvchisi to'xtatildi"
    pkill -f 'bfp-tailscale[.]sh' 2>/dev/null && log "eski funnel skripti to'xtatildi"
  fi

  # Eski node kaliti (100.91.30.56) — Render env'idagi DB_TAILNET_HOST shu IP'ga bog'langan.
  if [ ! -s "$STATE" ]; then
    if [ -f "$BUNDLE/state.tar.gz" ]; then
      log "tailscale holati ko'chirilmoqda (node kaliti)"
      if tar xzf "$BUNDLE/state.tar.gz" -C "$TS_DIR" 2>/dev/null; then
        [ -f "$TS_DIR/state2" ] && mv -f "$TS_DIR/state2" "$STATE"
        [ -d "$TS_DIR/var2" ] && mv -f "$TS_DIR/var2" "$STATEDIR"
        chmod 600 "$STATE" 2>/dev/null
      else
        log "OGOHLANTIRISH: holat arxivi ochilmadi"
      fi
    fi
  fi
  if [ -f "$BUNDLE/authkey" ] && [ ! -s "$KEYFILE" ]; then
    cp "$BUNDLE/authkey" "$KEYFILE" 2>/dev/null && chmod 600 "$KEYFILE"
  fi
  [ -s "$STATE" ] || log "OGOHLANTIRISH: eski holat yo'q — yangi node bo'lib qo'shiladi, IP o'zgaradi"

  install_boot || log "XATO: boot hook yozilmadi"
  install_bashrc

  # Eski (adb/shell) nusxa hali tirik bo'lsa, u bilan urishmasligi uchun avval shu bayroq.
  : >"$BUNDLE/termux-active" 2>/dev/null
  log "eski (shell) nusxa bo'lsa, o'zi to'xtaydi — kutamiz"
  sleep 25

  start_supervisor

  i=0
  while [ "$i" -lt 60 ]; do
    i=$((i + 1))
    [ "$(backend_state)" = "Running" ] && ts ip -4 >/dev/null 2>&1 && break
    sleep 2
  done
  log "=== o'rnatish tugadi ==="
  show_status
  if [ -s "$STATE" ]; then
    rm -f "$BUNDLE/authkey" "$BUNDLE/state.tar.gz"
    log "vaqtinchalik fayllar (authkey, holat arxivi) o'chirildi"
  else
    log "OGOHLANTIRISH: holat arxivi o'chirilmadi — ~/.ts2/state bo'sh"
  fi
}

# Bir buyruq bilan hammasini tiklaydi: baza + tunnel + serve yo'li + kuzatuvchi.
# Telefon qayta yonganda, Termux o'ldirilganda yoki tunnel uzilganda ishlatiladi.
do_repair() {
  log "=== tuzatish (repair) boshlandi ==="
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null && log "eski kuzatuvchi to'xtatildi"
    rm -f "$PIDFILE"
  fi
  command -v pkill >/dev/null 2>&1 && pkill -f "tailscaled.*$STATE" 2>/dev/null
  sleep 2

  ensure_pg
  if pg_listening; then
    log "baza: 127.0.0.1:$TCP_PORT ochiq"
  else
    log "XATO: baza 127.0.0.1:$TCP_PORT da ko'tarilmadi"
  fi

  ensure_bin || log "XATO: tailscale binarlari tayyor emas"
  start_daemon || log "XATO: tailscaled ko'tarilmadi"
  ensure_up
  if [ "$(backend_state)" = "Running" ]; then
    ts serve reset >/dev/null 2>&1 && log "serve yo'llari tozalandi"
  fi
  ensure_serve

  start_supervisor
  echo
  show_status
  log "=== tuzatish tugadi ==="
  if ! pg_listening; then
    log "baza ko'tarilmadi: $PG_DATA/server.log ni tekshiring"
    return 1
  fi
}

supervise() {
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null &&
    [ "$(cat "$PIDFILE" 2>/dev/null)" != "$$" ]; then
    echo "kuzatuvchi allaqachon ishlayapti (pid $(cat "$PIDFILE"))"
    return 0
  fi
  echo $$ >"$PIDFILE"
  command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null
  log "kuzatuvchi boshlandi (pid $$, node $NODE)"
  ensure_bin || return 1

  LAST_IP=""
  DB_OK=""
  FAILS=0
  API_FAILS=0
  NEXT_NET=0
  while :; do
    # Termux nusxasi ishga tushgan bo'lsa, ko'prik (shell) o'zini to'xtatadi.
    if [ "$BFP_BRIDGE" = "1" ] && [ -f "$BUNDLE/termux-active" ]; then
      log "Termux kuzatuvchisi tayyor — ko'prik to'xtatilmoqda"
      command -v pkill >/dev/null 2>&1 && pkill -f "tailscaled.*$STATE" 2>/dev/null
      rm -f "$PIDFILE"
      exit 0
    fi

    if ! daemon_up; then
      start_daemon || {
        FAILS=$((FAILS + 1))
        log "qayta urinish ${FAILS}/5 — 30s kutamiz"
        sleep 30
        continue
      }
    fi
    FAILS=0

    ensure_up
    ensure_serve
    ensure_pg

    # Har KEEPALIVE soniyada: API'ni uyg'oq tutish + tailnet ping tekshiruvi.
    NOW="$(date +%s)"
    if [ "$NOW" -ge "$NEXT_NET" ]; then
      NEXT_NET=$((NOW + KEEPALIVE))
      # Telefon uxlab qolmasligi uchun wake-lock har sikl'da qayta olinadi.
      command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null
      keep_api_awake
      tailnet_ping
    fi

    IP="$(ts ip -4 | head -1)"
    if [ -n "$IP" ] && [ "$IP" != "$LAST_IP" ]; then
      log "tailnet IP: $IP"
      if [ -n "$LAST_IP" ]; then
        log "OGOHLANTIRISH: IP o'zgardi ($LAST_IP -> $IP) — Render'da DB_TAILNET_HOST=$IP qilib qo'yish kerak"
      fi
      LAST_IP="$IP"
    fi

    # Mahalliy baza javob beradimi (PostgreSQL alohida boot skriptida ko'tariladi).
    if [ -n "${BASH_VERSION:-}" ]; then
      if (exec 3<>/dev/tcp/127.0.0.1/"$TCP_PORT") 2>/dev/null; then
        [ "$DB_OK" = "1" ] || log "baza 127.0.0.1:$TCP_PORT da javob beradi"
        DB_OK=1
      else
        [ "$DB_OK" = "0" ] || log "OGOHLANTIRISH: 127.0.0.1:$TCP_PORT javob bermayapti (PostgreSQL ko'tarilganini tekshiring)"
        DB_OK=0
      fi
    fi

    sleep 10
  done
}

case "${1:-}" in
  --install) do_install ;;
  --repair) do_repair ;;
  --status) show_status ;;
  --stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
    command -v pkill >/dev/null 2>&1 && pkill -f "tailscaled.*$STATE" 2>/dev/null
    rm -f "$PIDFILE"
    log "to'xtatildi"
    ;;
  "") supervise ;;
  *)
    echo "ishlatish: $0 [--install|--repair|--status|--stop]" >&2
    exit 1
    ;;
esac
