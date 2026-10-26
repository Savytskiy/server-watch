#!/usr/bin/env bash
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin

CONF_DIR=/etc/server-watch
DATA_DIR=/var/lib/server-watch
STATE_FILE="$DATA_DIR/state.tsv"
IGNORE_VMIDS_FILE="$CONF_DIR/ignore_vmids.txt"
ENV_FILE="$CONF_DIR/config.env"
# One line per systemd unit (or a bash glob against it) currently in a
# deliberate, controlled maintenance window - any project's own
# deploy/maintenance.sh writes/removes its own unit names here so a planned
# `systemctl stop` during a deploy never pages anyone. This is intentionally
# a shared, cross-project file (this script itself watches every project on
# the host, not just one) rather than each project inventing its own
# skip-list convention.
MAINTENANCE_UNITS_FILE="$CONF_DIR/maintenance_units.txt"

install -d -m 700 "$DATA_DIR"
touch "$STATE_FILE"
chmod 600 "$STATE_FILE"

[[ -f "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }

alert() {
  # alert <severity> <fingerprint> <title> [message]
  local severity="$1" fingerprint="$2" title="$3" message="${4:-}"
  [[ -n "${ALERT_BOT_URL:-}" && -n "${ALERT_BOT_TOKEN:-}" ]] || return 0
  local payload
  payload="$(python3 - "$severity" "$title" "$message" "$fingerprint" <<'PY'
import json, sys
print(json.dumps({"severity": sys.argv[1], "title": sys.argv[2], "message": sys.argv[3], "fingerprint": sys.argv[4]}))
PY
)"
  curl -sS --max-time 10 -X POST "${ALERT_BOT_URL}/webhook/${ALERT_BOT_TOKEN}" \
    -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1 || true
}

unit_in_maintenance() {
  local unit="$1" pattern
  [[ -f "$MAINTENANCE_UNITS_FILE" ]] || return 1
  while IFS= read -r pattern; do
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    # shellcheck disable=SC2053 - deliberate glob match, e.g. "madgamehunter-*"
    [[ "$unit" == $pattern ]] && return 0
  done < "$MAINTENANCE_UNITS_FILE"
  return 1
}

# Ignore VMIDs (templates etc.)
declare -A IGNORE
if [[ -f "$IGNORE_VMIDS_FILE" ]]; then
  while read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] && IGNORE["$id"]=1
  done < <(grep -E '^[0-9]+' "$IGNORE_VMIDS_FILE" 2>/dev/null || true)
fi

now="$(date +%s)"

# duration thresholds (seconds) - one host now, tighter than the old multi-host fleet setup
TH_LOAD_SEC=$((30*60))
TH_IDLE_SEC=$((30*60))
TH_MEM_SEC=$((30*60))
TH_SWAP_SEC=$((30*60))
TH_IOWAIT_SEC=$((60*60))
TH_DISK_WARN_SEC=$((15*60))
TH_DISK_CRIT_SEC=$((10*60))
# A VM is down or its agent silent this long before paging: a Windows guest
# rebooting for updates (or still installing) is quiet for minutes, not 10.
TH_VM_SEC=$((10*60))

state_get() {
  local m="$1"
  awk -v m="$m" 'BEGIN{FS="\t"} $1==m {print $2; found=1} END{if(!found) print "0"}' "$STATE_FILE"
}
state_set() {
  local m="$1" since="$2"
  awk -v m="$m" -v since="$since" 'BEGIN{FS=OFS="\t"} {if($1==m){$2=since;seen=1}; print} END{if(!seen) print m,since}' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}
state_clear() {
  local m="$1"
  awk -v m="$m" 'BEGIN{FS=OFS="\t"} {if($1!=m) print}' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# duration-gated alert: fires once condition has been true for >= threshold seconds.
# de-dup of repeat firings is left to alert-bot (same fingerprint => edits "повторилось N раз").
maybe_alert() {
  local metric="$1" is_true="$2" threshold="$3" severity="$4" fingerprint="$5" title="$6" message="${7:-}"
  local since
  since="$(state_get "$metric")"
  if [[ "$is_true" == "1" ]]; then
    if [[ "$since" == "0" ]]; then
      state_set "$metric" "$now"
      return 0
    fi
    if (( now - since >= threshold )); then
      alert "$severity" "$fingerprint" "$title" "$message"
    fi
  else
    state_clear "$metric"
  fi
}

# ---------- VMs: running + qemu-agent ping ----------
while read -r VMID NAME STATUS _rest; do
  [[ -z "${VMID:-}" ]] && continue
  [[ -n "${IGNORE[$VMID]:-}" ]] && continue
  IS_TPL=0
  qm config "$VMID" 2>/dev/null | grep -q '^template: 1' && IS_TPL=1
  [[ "$IS_TPL" == "1" ]] && continue

  not_running=0; agent_silent=0
  if [[ "$STATUS" != "running" ]]; then
    not_running=1
  elif ! timeout 3 qm agent "$VMID" ping >/dev/null 2>&1; then
    agent_silent=1
  fi
  maybe_alert "vm_not_running:${VMID}" "$not_running" "$TH_VM_SEC" critical \
    "vm-not-running:${VMID}" "VM NOT RUNNING" "VMID=${VMID} name=${NAME} status=${STATUS}"
  maybe_alert "vm_agent_silent:${VMID}" "$agent_silent" "$TH_VM_SEC" critical \
    "vm-agent-fail:${VMID}" "VM AGENT NO PING" "VMID=${VMID} name=${NAME}"
done < <(qm list 2>/dev/null | awk 'NR>1{print $1,$2,$3}')

# ---------- nightly backup heartbeat ----------
# backup.sh stamps /var/lib/server-backup/last_ok after each successful run.
# Its own FAILED alert only fires when it runs; this catches it not running.
BACKUP_STAMP=/var/lib/server-backup/last_ok
BACKUP_MAX_AGE_SEC=$((30*60*60))
if [[ -f "$BACKUP_STAMP" ]]; then
  last_ok="$(cat "$BACKUP_STAMP" 2>/dev/null || echo 0)"
  if (( now - last_ok > BACKUP_MAX_AGE_SEC )); then
    alert "critical" "backup-stale" "BACKUP NOT RUNNING" \
      "last successful backup $(( (now - last_ok) / 3600 ))h ago (check: systemctl status server-backup.timer)"
  fi
fi

# ---------- RAID / mdstat ----------
MD="$(cat /proc/mdstat 2>/dev/null || true)"
while read -r mdline; do
  mdname="$(awk '{print $1}' <<<"$mdline")"
  [[ -z "$mdname" ]] && continue
  detail="$(echo "$MD" | grep -A1 "^${mdname} :" | tr '\n' ' ')"
  if echo "$detail" | grep -Eq '\[.*_.*\]'; then
    alert "critical" "raid-degraded:${mdname}" "RAID DEGRADED/FAULTY: ${mdname}" "$(echo "$detail" | xargs)"
  fi
  if echo "$detail" | grep -Eqi '\(F\)'; then
    alert "critical" "raid-faulty-disk:${mdname}" "RAID FAULTY DISK: ${mdname}" "$(echo "$detail" | xargs)"
  fi
  if echo "$detail" | grep -Eqi 'resync|recovery|reshape|check|repair'; then
    alert "info" "raid-resync:${mdname}" "RAID RESYNC/RECOVERY: ${mdname}" "$(echo "$detail" | xargs)"
  fi
done < <(echo "$MD" | grep -E '^md[0-9]+ :')

# ---------- SMART (NVMe) ----------
for dev in /dev/nvme0n1 /dev/nvme1n1; do
  [[ -e "$dev" ]] || continue
  H="$(smartctl -H "$dev" 2>/dev/null || true)"
  if ! echo "$H" | grep -qi "PASSED"; then
    alert "critical" "smart-health:${dev}" "SMART HEALTH FAIL: ${dev}" "$(echo "$H" | grep -i result)"
  fi
  A="$(smartctl -A "$dev" 2>/dev/null || true)"
  media_err="$(echo "$A" | awk -F: '/Media and Data Integrity Errors/{gsub(/[^0-9]/,"",$2); print $2}')"
  pct_used="$(echo "$A" | awk -F: '/Percentage Used/{gsub(/[^0-9]/,"",$2); print $2}')"
  temp="$(echo "$A" | awk -F: '/^Temperature:/{gsub(/[^0-9]/,"",$2); print $2}')"

  if [[ -n "${media_err:-}" ]] && (( media_err > 0 )); then
    alert "critical" "smart-media-errors:${dev}" "SMART MEDIA ERRORS: ${dev}" "count=${media_err}"
  fi
  if [[ -n "${pct_used:-}" ]]; then
    if (( pct_used >= 90 )); then
      alert "critical" "smart-wear:${dev}" "SMART WEAR CRITICAL: ${dev}" "percentage_used=${pct_used}%"
    elif (( pct_used >= 80 )); then
      alert "warning" "smart-wear:${dev}" "SMART WEAR HIGH: ${dev}" "percentage_used=${pct_used}%"
    fi
  fi
  if [[ -n "${temp:-}" ]]; then
    if (( temp >= 85 )); then
      alert "critical" "smart-temp:${dev}" "NVMe TEMP CRITICAL: ${dev}" "${temp}C"
    elif (( temp >= 75 )); then
      alert "warning" "smart-temp:${dev}" "NVMe TEMP HIGH: ${dev}" "${temp}C"
    fi
  fi
done

# ---------- Disk usage ----------
disk_pct="$(df -P / | awk 'NR==2{gsub("%","",$5);print $5}')"
disk_warn=0; disk_crit=0
(( disk_pct >= 95 )) && disk_crit=1
(( disk_pct >= 85 && disk_pct < 95 )) && disk_warn=1
maybe_alert "disk_crit" "$disk_crit" "$TH_DISK_CRIT_SEC" "critical" "disk-usage-critical:/" "DISK >=95% (10m)" "/=${disk_pct}%"
maybe_alert "disk_warn" "$disk_warn" "$TH_DISK_WARN_SEC" "warning"  "disk-usage-warning:/"  "DISK >=85% (15m)" "/=${disk_pct}%"

# ---------- RAM / swap ----------
memavail_kb="$(awk '/MemAvailable/{print $2}' /proc/meminfo)"
swap_t_kb="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
swap_f_kb="$(awk '/SwapFree/{print $2}' /proc/meminfo)"
swap_u_kb="$((swap_t_kb - swap_f_kb))"

mem_lo=0; (( memavail_kb < 3*1024*1024 )) && mem_lo=1
# Swap that is merely occupied (idle pages pushed out long ago) is harmless;
# what hurts is the system reading it back in. Alert on a sustained swap-in
# rate (~1 MB/s), or when swap fills a large share of RAM anyway.
pswpin="$(awk '/^pswpin /{print $2}' /proc/vmstat)"
now_ts="$(date +%s)"
prev_pswpin="$(state_get swap_pswpin_last)"; prev_ts="$(state_get swap_ts_last)"
state_set swap_pswpin_last "$pswpin"; state_set swap_ts_last "$now_ts"
swapin_ps=0
(( prev_ts > 0 && now_ts > prev_ts && pswpin >= prev_pswpin )) && swapin_ps=$(( (pswpin - prev_pswpin) / (now_ts - prev_ts) ))
swap_hi=0; (( swapin_ps > 250 || swap_u_kb > 24*1024*1024 )) && swap_hi=1
maybe_alert "mem_lo" "$mem_lo" "$TH_MEM_SEC" "warning" "ram-low" "RAM LOW (30m)" "MemAvailable=$((memavail_kb/1024))MB"
maybe_alert "swap_hi" "$swap_hi" "$TH_SWAP_SEC" "warning" "swap-pressure" "SWAP PRESSURE (30m)" "SwapUsed=$((swap_u_kb/1024))MB swap-in=${swapin_ps} pages/s"

# ---------- Load / iowait ----------
nproc_n="$(nproc)"
load1="$(awk '{print $1}' /proc/loadavg)"
VM="$(vmstat 1 2 | tail -1)"
idle="$(awk '{print $15}' <<<"$VM")"
iowait="$(awk '{print $16}' <<<"$VM")"

load_hi=0
awk -v l="$load1" -v n="$nproc_n" 'BEGIN{exit !(l > (0.90*n))}' && load_hi=1
idle_lo=0
awk -v i="$idle" 'BEGIN{exit !(i < 5)}' && idle_lo=1
iow_hi=0
awk -v w="$iowait" 'BEGIN{exit !(w > 15)}' && iow_hi=1

maybe_alert "load_hi" "$load_hi" "$TH_LOAD_SEC" "warning" "load-high" "LOAD HIGH (30m)" "load1=${load1} nproc=${nproc_n}"
maybe_alert "idle_lo" "$idle_lo" "$TH_IDLE_SEC" "warning" "cpu-idle-low" "CPU IDLE LOW (30m)" "idle=${idle}% iowait=${iowait}%"
maybe_alert "iow_hi"  "$iow_hi"  "$TH_IOWAIT_SEC" "warning" "iowait-high" "IO WAIT HIGH (60m)" "iowait=${iowait}%"

declare -A FAILED_UNITS
# ---------- systemd failed units ----------
# One notification per continuous failed-unit incident. Reposting on every
# server-watch tick edits the same Alert Bot incident hundreds of times and
# can fan out into email spam; alert again only after the unit recovers and
# subsequently fails (the state is cleared below once it leaves --failed).
while read -r unit; do
  [[ -z "$unit" ]] && continue
  unit_in_maintenance "$unit" && continue
  FAILED_UNITS["$unit"]=1
  metric="systemd_failed_last:${unit}"
  if [[ "$(state_get "$metric")" == "0" ]]; then
    alert "critical" "systemd-failed:${unit}" "SYSTEMD UNIT FAILED: ${unit}" ""
    state_set "$metric" "$now"
  fi
done < <(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
while IFS= read -r metric; do
  unit="${metric#systemd_failed_last:}"
  if [[ -z "${FAILED_UNITS[$unit]:-}" ]]; then
    state_clear "$metric"
  fi
done < <(awk -F '\t' '$1 ~ /^systemd_failed_last:/ {print $1}' "$STATE_FILE")

# ---------- Docker containers ----------
if command -v docker >/dev/null 2>&1; then
  while IFS=$'\t' read -r name state status; do
    [[ -z "$name" ]] && continue
    if [[ "$state" == "restarting" ]]; then
      alert "critical" "docker-restart-loop:${name}" "DOCKER CONTAINER RESTART-LOOPING: ${name}" "status=${status}"
    elif [[ "$state" == "exited" && "$status" != *"Exited (0)"* ]]; then
      alert "critical" "docker-down:${name}" "DOCKER CONTAINER DOWN (non-zero exit): ${name}" "status=${status}"
    fi
  done < <(docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Status}}' 2>/dev/null)
fi

# ---------- Local HTTP services ----------
TH_ADMIN_PANEL_SEC=90
admin_panel_down=0
curl -fsS --max-time 5 http://127.0.0.1:8020/health >/dev/null 2>&1 || admin_panel_down=1
maybe_alert "admin_panel_down" "$admin_panel_down" "$TH_ADMIN_PANEL_SEC" "critical" "admin-panel-down" "ADMIN PANEL DOWN" "GET /health failed on 127.0.0.1:8020"

# ---------- MadGame Hunter: watch the in-process watchdog itself ----------
# tasks.watchdog (inside madgamehunter-worker.service) is what's supposed to
# catch a stalled background loop - but it runs inside the SAME asyncio
# process as the loops it monitors, so it's exactly as vulnerable to being
# silently frozen alongside them (confirmed live: a stalled Gemini call with
# no timeout in tasks.giveaway_updater froze that whole worker subprocess's
# event loop, and tasks.watchdog - co-located on it - went dark for 11 days
# too, producing zero log output and zero alerts the entire time). This
# check is deliberately OUTSIDE that process (a separate bash script on its
# own systemd timer) specifically so it keeps working even if the Python
# side wedges completely. It reads the exact same Redis heartbeat key
# tasks.watchdog's own TaskLock.renew() writes on every tick (see
# app.services.task_lock.HEARTBEAT_KEY_SUFFIX) - a stale/missing value here
# means nobody is watching the other loops right now.
TH_MGH_WATCHDOG_SEC=$((15*60))
if unit_in_maintenance "madgamehunter-worker.service"; then
  state_clear "mgh_watchdog_stale"
else
  mgh_watchdog_stale=0
  mgh_hb_raw="$(docker exec madgamehunter_redis redis-cli -a "${MADGAMEHUNTER_REDIS_PASSWORD:-}" --no-auth-warning GET "watchdog:running_lock:heartbeat" 2>/dev/null)"
  if [[ -z "$mgh_hb_raw" ]]; then
    mgh_watchdog_stale=1
  else
    mgh_hb_int="${mgh_hb_raw%.*}"
    if [[ "$mgh_hb_int" =~ ^[0-9]+$ ]]; then
      mgh_age=$(( $(date +%s) - mgh_hb_int ))
      (( mgh_age > 300 )) && mgh_watchdog_stale=1
    else
      mgh_watchdog_stale=1
    fi
  fi
  maybe_alert "mgh_watchdog_stale" "$mgh_watchdog_stale" "$TH_MGH_WATCHDOG_SEC" "critical" "madgamehunter-watchdog-stale" "MADGAMEHUNTER WATCHDOG SILENT (15m+)" "tasks.watchdog heartbeat missing/stale - nothing is monitoring the background loops right now, check madgamehunter-worker.service"
fi

# ---------- Certbot cert expiry ----------
if command -v certbot >/dev/null 2>&1; then
  cur_name=""
  while read -r line; do
    if [[ "$line" =~ Certificate\ Name:\ (.+) ]]; then
      cur_name="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ VALID:\ ([0-9]+)\ days? ]]; then
      days="${BASH_REMATCH[1]}"
      if (( days < 3 )); then
        alert "critical" "cert-expiry:${cur_name}" "CERT EXPIRES SOON: ${cur_name}" "${days} days left"
      elif (( days < 14 )); then
        alert "warning" "cert-expiry:${cur_name}" "CERT EXPIRES SOON: ${cur_name}" "${days} days left"
      fi
    fi
  done < <(certbot certificates 2>/dev/null)
fi

# ---------- Reboot required ----------
if [[ -f /var/run/reboot-required ]]; then
  pkgs="$(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ',' || true)"
  alert "info" "reboot-required" "REBOOT REQUIRED" "${pkgs}"
fi

exit 0
