#!/bin/bash
################################################################################
# backup_flex.sh — ГИБКИЙ FULL/INCR backup (GNU tar incremental) v4.2-minimal
#
# Изменения относительно исходника:
#  - добавлен переключатель уведомлений: telegram/email/both/none
#  - добавлена отправка уведомлений на email через SMTP
#  - для SMTP используется AUTH=LOGIN
#  - остальная логика максимально сохранена
# 
# Возможности:
#  - FULL в выбранные дни недели + в выбранные часы (может быть несколько)
#  - INCR в выбранные дни недели + в выбранные часы (может быть несколько)
#  - Папки: YYYY-MM-DD_HH-MM-SS
#  - Инкременты привязаны к последнему FULL через chain (tar snapshot .snar)
#  - Ретеншн: удаляет старые full/incremental/chains старше N дней
#
# Запуск:
#  ./backup_flex.sh --mode full
#  ./backup_flex.sh --mode incr
#  ./backup_flex.sh --mode auto        # сам определит по расписанию из conf
#
# Рекомендовано:
#  запускать по systemd timers (каждый timer вызывает нужный --mode)
################################################################################

set -euo pipefail

# ----------------------- аргументы -----------------------
MODE="auto"
CONF="/home/admin2/backup/backup_flex.conf"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2;;
    --conf) CONF="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 2;;
  esac
done

# ----------------------- конфиг -------------------------
if [[ -f "$CONF" ]]; then
  # shellcheck source=/dev/null
  source "$CONF"
else
  echo "Config not found: $CONF"
  exit 1
fi

# ----------------------- defaults -----------------------
AUTO_TOLERANCE_MIN="${AUTO_TOLERANCE_MIN:-2}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
NOTIFY_MODE="${NOTIFY_MODE:-telegram}"
SMTP_SCHEME="${SMTP_SCHEME:-starttls}"

# ----------------------- dirs --------------------------
DIR_FULL="${BACKUP_BASE}/full"
DIR_INCR="${BACKUP_BASE}/incremental"
DIR_CHAINS="${BACKUP_BASE}/chains"
DIR_LOGS="${BACKUP_BASE}/logs"

mkdir -p "$DIR_FULL" "$DIR_INCR" "$DIR_CHAINS" "$DIR_LOGS"

TS="$(date +%Y-%m-%d_%H-%M-%S)"
DATE_HUMAN="$(date '+%d.%m.%Y %H:%M:%S')"
DOW="$(date +%u)"          # 1..7
HM="$(date +%H:%M)"

LOG_FILE="${DIR_LOGS}/backup_${TS}.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ----------------------- notifications -----------------
send_telegram() {
  local msg="$1"

  [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || return 0
  [[ -n "${TELEGRAM_CHAT_ID:-}" ]] || return 0

  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${msg}" \
    >/dev/null 2>&1 || true
}

send_email() {
  local subject="$1"
  local body="$2"
  local mail_file smtp_url

  [[ -n "${SMTP_HOST:-}" ]] || return 0
  [[ -n "${SMTP_PORT:-}" ]] || return 0
  [[ -n "${MAIL_FROM:-}" ]] || return 0
  [[ -n "${MAIL_TO:-}" ]] || return 0

  mail_file="$(mktemp)"

  cat > "$mail_file" <<EOF
From: ${MAIL_FROM}
To: ${MAIL_TO}
Subject: ${subject}
Date: $(date -R)
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 8bit

${body}
EOF

  case "${SMTP_SCHEME}" in
    ssl)
      smtp_url="smtps://${SMTP_HOST}:${SMTP_PORT}"
      ;;
    none)
      smtp_url="smtp://${SMTP_HOST}:${SMTP_PORT}"
      ;;
    *)
      smtp_url="smtp://${SMTP_HOST}:${SMTP_PORT}"
      ;;
  esac

  if [[ -n "${SMTP_USER:-}" ]]; then
    if [[ "${SMTP_SCHEME}" == "ssl" ]]; then
      curl -s --url "$smtp_url" \
        --user "${SMTP_USER}:${SMTP_PASS:-}" \
        --login-options "AUTH=LOGIN" \
        --mail-from "$MAIL_FROM" \
        --mail-rcpt "$MAIL_TO" \
        --upload-file "$mail_file" \
        >/dev/null 2>&1 || true
    elif [[ "${SMTP_SCHEME}" == "none" ]]; then
      curl -s --url "$smtp_url" \
        --user "${SMTP_USER}:${SMTP_PASS:-}" \
        --login-options "AUTH=LOGIN" \
        --mail-from "$MAIL_FROM" \
        --mail-rcpt "$MAIL_TO" \
        --upload-file "$mail_file" \
        >/dev/null 2>&1 || true
    else
      curl -s --url "$smtp_url" --ssl-reqd \
        --user "${SMTP_USER}:${SMTP_PASS:-}" \
        --login-options "AUTH=LOGIN" \
        --mail-from "$MAIL_FROM" \
        --mail-rcpt "$MAIL_TO" \
        --upload-file "$mail_file" \
        >/dev/null 2>&1 || true
    fi
  else
    if [[ "${SMTP_SCHEME}" == "ssl" ]]; then
      curl -s --url "$smtp_url" \
        --mail-from "$MAIL_FROM" \
        --mail-rcpt "$MAIL_TO" \
        --upload-file "$mail_file" \
        >/dev/null 2>&1 || true
    elif [[ "${SMTP_SCHEME}" == "none" ]]; then
      curl -s --url "$smtp_url" \
        --mail-from "$MAIL_FROM" \
        --mail-rcpt "$MAIL_TO" \
        --upload-file "$mail_file" \
        >/dev/null 2>&1 || true
    else
      curl -s --url "$smtp_url" --ssl-reqd \
        --mail-from "$MAIL_FROM" \
        --mail-rcpt "$MAIL_TO" \
        --upload-file "$mail_file" \
        >/dev/null 2>&1 || true
    fi
  fi

  rm -f "$mail_file"
}

notify() {
  local subject="$1"
  local message="$2"

  case "$NOTIFY_MODE" in
    telegram)
      send_telegram "$message"
      ;;
    email)
      send_email "$subject" "$message"
      ;;
    both)
      send_telegram "$message"
      send_email "$subject" "$message"
      ;;
    none)
      ;;
    *)
      send_telegram "$message"
      ;;
  esac
}

die() {
  local msg="$1"
  log "✗ КРИТИЧЕСКАЯ ОШИБКА: $msg"
  notify \
    "ОШИБКА БЕКАПА $(hostname)" \
    "ОШИБКА БЕКАПА

Хост: $(hostname)
Дата: ${DATE_HUMAN}

Ошибка: ${msg}"
  exit 1
}

filesize() {
  du -h "$1" 2>/dev/null | awk '{print $1}' || echo "?"
}

# ----------------------- schedule helpers --------------
in_array() {
  local needle="$1"; shift
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

time_matches() {
  # true если текущее время HM совпадает с любым из списка TIMES с допуском ±AUTO_TOLERANCE_MIN
  local now_min target tol
  tol="$AUTO_TOLERANCE_MIN"
  now_min=$((10#$(date +%H)*60 + 10#$(date +%M)))

  for target in "$@"; do
    local th tm tmin diff
    th="${target%:*}"
    tm="${target#*:}"
    tmin=$((10#$th*60 + 10#$tm))
    diff=$(( now_min - tmin ))
    (( diff < 0 )) && diff=$(( -diff ))
    if (( diff <= tol )); then
      return 0
    fi
  done
  return 1
}

decide_mode_auto() {
  # FULL имеет приоритет, если попали в расписание FULL
  if in_array "$DOW" "${FULL_DAYS[@]}" && time_matches "${FULL_TIMES[@]}"; then
    echo "full"
    return
  fi
  if in_array "$DOW" "${INCR_DAYS[@]}" && time_matches "${INCR_TIMES[@]}"; then
    echo "incr"
    return
  fi
  echo "skip"
}

# ----------------------- choose mode --------------------
if [[ "$MODE" == "auto" ]]; then
  MODE="$(decide_mode_auto)"
  if [[ "$MODE" == "skip" ]]; then
    log "⏭ AUTO: текущее время ${HM} не попадает ни в FULL, ни в INCR расписание — выходим."
    exit 0
  fi
fi

if [[ "$MODE" != "full" && "$MODE" != "incr" ]]; then
  die "Неверный --mode. Разрешено: full|incr|auto"
fi

# ----------------------- chain logic --------------------
# Каждому FULL соответствует chain (цепочка). INCR всегда пишет в текущую chain.
# current -> симлинк на последнюю chain
CHAIN_CURRENT_LINK="${DIR_CHAINS}/current"

create_new_chain() {
  local chain_id chain_dir
  chain_id="$TS"  # chain id = timestamp full backup
  chain_dir="${DIR_CHAINS}/${chain_id}"
  mkdir -p "$chain_dir"
  ln -sfn "$chain_dir" "$CHAIN_CURRENT_LINK"
  echo "$chain_id"
}

get_current_chain_dir() {
  if [[ -L "$CHAIN_CURRENT_LINK" ]]; then
    readlink -f "$CHAIN_CURRENT_LINK"
  else
    echo ""
  fi
}

# ----------------------- run dirs -----------------------
if [[ "$MODE" == "full" ]]; then
  RUN_DIR="${DIR_FULL}/${TS}"
else
  RUN_DIR="${DIR_INCR}/${TS}"
fi
mkdir -p "$RUN_DIR"

DB_BACKUP="${RUN_DIR}/db_${MODE}_${TS}.sql.gz"
SITE_BACKUP="${RUN_DIR}/site_${MODE}_${TS}.tar.gz"

# ----------------------- start -------------------------
log "=========================================="
log "  ЗАПУСК БЕКАПА v4.2-minimal"
log "  MODE: ${MODE} | DOW: ${DOW} | TIME: ${HM}"
log "  RUN_DIR: ${RUN_DIR}"
log "=========================================="

# ----------------------- FULL/INCR chain selection -----
if [[ "$MODE" == "full" ]]; then
  CHAIN_ID="$(create_new_chain)"
  CHAIN_DIR="$(get_current_chain_dir)"
  SNAR_FILE="${CHAIN_DIR}/site.snar"
  rm -f "$SNAR_FILE"  # reset snar for full
  log "Создана новая chain: ${CHAIN_ID}"
else
  CHAIN_DIR="$(get_current_chain_dir)"
  if [[ -z "$CHAIN_DIR" ]]; then
    log "⚠️ Нет активной chain (полного бекапа). Переключаюсь на FULL."
    MODE="full"
    RUN_DIR="${DIR_FULL}/${TS}"
    mkdir -p "$RUN_DIR"
    DB_BACKUP="${RUN_DIR}/db_full_${TS}.sql.gz"
    SITE_BACKUP="${RUN_DIR}/site_full_${TS}.tar.gz"
    CHAIN_ID="$(create_new_chain)"
    CHAIN_DIR="$(get_current_chain_dir)"
    SNAR_FILE="${CHAIN_DIR}/site.snar"
    rm -f "$SNAR_FILE"
  else
    CHAIN_ID="$(basename "$CHAIN_DIR")"
    SNAR_FILE="${CHAIN_DIR}/site.snar"
  fi
  log "Использую chain: ${CHAIN_ID}"
fi

notify \
  "Бекап запущен $(hostname)" \
  "Бекап запущен

Хост: $(hostname)
Дата: ${DATE_HUMAN}
Mode: ${MODE}"

# ----------------------- DB backup ----------------------
log "---- БЕКАП MySQL ----"
rm -f "$DB_BACKUP"
mysqldump -h "$DB_HOST" -P"$DB_PORT" -u "$DB_USER" -p"$DB_PASS" \
  --column-statistics=0 \
  --single-transaction \
  --routines --triggers --events \
  --no-tablespaces \
  "$DB_NAME" 2>>"$LOG_FILE" | gzip -9 > "$DB_BACKUP" || die "mysqldump завершился с ошибкой"

[[ -s "$DB_BACKUP" ]] || die "DB_BACKUP пустой: $DB_BACKUP"
DB_SIZE="$(filesize "$DB_BACKUP")"
log "✓ DB OK: $(basename "$DB_BACKUP") (${DB_SIZE})"

# ----------------------- SITE backup --------------------
log "---- БЕКАП САЙТА (GNU tar incremental) ----"
rm -f "$SITE_BACKUP"

tar --listed-incremental="$SNAR_FILE" \
  "${TAR_EXCLUDES[@]}" \
  -czf "$SITE_BACKUP" \
  "$SITE_PATH" 2>>"$LOG_FILE" || die "tar завершился с ошибкой"

[[ -s "$SITE_BACKUP" ]] || die "SITE_BACKUP пустой: $SITE_BACKUP"
SITE_SIZE="$(filesize "$SITE_BACKUP")"
log "✓ SITE OK: $(basename "$SITE_BACKUP") (${SITE_SIZE})"

# Сохраним копию снапшота рядом с запуском (для удобства аудита)
cp -f "$SNAR_FILE" "${RUN_DIR}/site.snar" 2>/dev/null || true

# ----------------------- SFTP upload --------------------
#log "---- SFTP UPLOAD ----"
#SFTP_REMOTE_DIR="${SFTP_REMOTE_BASE}/${MODE}/${TS}"

#SFTP_BATCH="$(mktemp)"
#cat > "$SFTP_BATCH" <<EOF
#-mkdir ${SFTP_REMOTE_BASE}
#-mkdir ${SFTP_REMOTE_BASE}/full
#-mkdir ${SFTP_REMOTE_BASE}/incr
#-mkdir ${SFTP_REMOTE_BASE}/full
#-mkdir ${SFTP_REMOTE_BASE}/incr
#-mkdir ${SFTP_REMOTE_DIR}
#cd ${SFTP_REMOTE_DIR}
#put ${DB_BACKUP}
#put ${SITE_BACKUP}
#bye
#EOF

#SFTP_STATUS="ok"
#sshpass -p "$SFTP_PASS" sftp \
#  -o PreferredAuthentications=password \
#  -o PubkeyAuthentication=no \
#  -o StrictHostKeyChecking=no \
#  -o ConnectTimeout=30 \
#  -P "$SFTP_PORT" \
#  -b "$SFTP_BATCH" \
#  "${SFTP_USER}@${SFTP_HOST}" >>"$LOG_FILE" 2>&1 || SFTP_STATUS="ошибка"

#SFTP_STATUS="ok"
#sshpass -p "$SFTP_PASS" sftp \
#  -o StrictHostKeyChecking=no \
#  -o ConnectTimeout=30 \
#  -P "$SFTP_PORT" \
#  -b "$SFTP_BATCH" \
#  "${SFTP_USER}@${SFTP_HOST}" >>"$LOG_FILE" 2>&1 || SFTP_STATUS="ошибка"

#rm -f "$SFTP_BATCH"
#log "SFTP: ${SFTP_STATUS}"

# ----------------------- SFTP upload --------------------
log "---- SFTP UPLOAD ----"

REMOTE_BASE="${SFTP_REMOTE_BASE:-files}"
REMOTE_BASE="${REMOTE_BASE#/}"
REMOTE_BASE="${REMOTE_BASE%/}"

if [[ -n "$REMOTE_BASE" ]]; then
  REMOTE_MODE_DIR="${REMOTE_BASE}/${MODE}"
else
  REMOTE_MODE_DIR="${MODE}"
fi

SFTP_BATCH="$(mktemp)"
cat > "$SFTP_BATCH" <<EOF
cd ${REMOTE_MODE_DIR}
-mkdir ${TS}
put ${DB_BACKUP} ${TS}/$(basename "$DB_BACKUP")
put ${SITE_BACKUP} ${TS}/$(basename "$SITE_BACKUP")
bye
EOF

SFTP_STATUS="ok"
sshpass -p "$SFTP_PASS" sftp \
  -oBatchMode=no \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=30 \
  -P "$SFTP_PORT" \
  -b "$SFTP_BATCH" \
  "${SFTP_USER}@${SFTP_HOST}" >>"$LOG_FILE" 2>&1 || SFTP_STATUS="ошибка"

rm -f "$SFTP_BATCH"
log "SFTP: ${SFTP_STATUS}"


# ----------------------- retention cleanup --------------
log "---- RETENTION CLEANUP ----"
find "$DIR_FULL" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} \; 2>>"$LOG_FILE" || true
find "$DIR_INCR" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} \; 2>>"$LOG_FILE" || true
find "$DIR_CHAINS" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -exec rm -rf {} \; 2>>"$LOG_FILE" || true
find "$DIR_LOGS" -type f -mtime +30 -delete 2>>"$LOG_FILE" || true

# ----------------------- done --------------------------
log "=========================================="
log "  ГОТОВО"
log "  MODE=${MODE} | chain=${CHAIN_ID}"
log "  DB=${DB_SIZE} | SITE=${SITE_SIZE} | SFTP=${SFTP_STATUS}"
log "=========================================="

notify \
  "Бекап завершён $(hostname)" \
  "Бекап завершён

Хост: $(hostname)
Дата: ${DATE_HUMAN}
Mode: ${MODE}
Chain: ${CHAIN_ID}

DB: ${DB_SIZE}
SITE: ${SITE_SIZE}
SFTP: ${SFTP_STATUS}

Run: ${RUN_DIR}"

exit 0
