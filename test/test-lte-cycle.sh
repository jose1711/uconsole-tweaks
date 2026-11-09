#!/bin/bash
# Power-cycle the SIM7600 repeatedly (no reboot) and record whether ModemManager
# + NetworkManager bring it up on their own. Optional A/B: stock vs. patched ModemManager.
#
#   test-lte-cycle.sh [-n CYCLES] [-m patched|stock|ab] [-o OUTDIR] [-f]
#
#   -n  cycles per variant (default 10)
#   -m  patched: test the installed ModemManager as is (default)
#       stock:   install the stock Debian ModemManager, test, restore the patched one
#       ab:      stock first, then patched (N cycles each), ends with patched installed
#   -o  output dir (default ./lte-test-<timestamp>), contains results.csv + debs/
#   -f  run even on battery / with LTE as default route
#
# Uses the ORIGINAL uconsole-4g-cm4.sh.orig for power sequencing so the local
# workarounds (MM restart, nmcli con up) cannot mask failures. Each cycle takes ~2-3 min.
# WARNING: drops the LTE link; run on a charger (USB hub brownouts on battery).

N=10; MODE=patched; OUT=; FORCE=0
while getopts n:m:o:f o; do case $o in
  n) N=$OPTARG;; m) MODE=$OPTARG;; o) OUT=$OPTARG;; f) FORCE=1;; *) sed -n 2,16p "$0"; exit 2;; esac; done
[[ $MODE =~ ^(patched|stock|ab)$ ]] || { echo "bad -m"; exit 2; }
OUT=${OUT:-./lte-test-$(date +%Y%m%d-%H%M%S)}
RAW=${RAW:-/usr/local/bin/uconsole-4g-cm4.sh.orig}
PATCHED_DIR=${PATCHED_DIR:-$HOME/modemmanager-patched}
STOCK_VER=${STOCK_VER:-1.24.0-1+deb13u1}
CON=${CON:-radost}
READY_TIMEOUT=${READY_TIMEOUT:-90}
[ -x "$RAW" ] || { echo "missing $RAW"; exit 1; }
mkdir -p "$OUT/debs"; CSV=$OUT/results.csv

if [ $FORCE = 0 ]; then
  grep -qs Discharging /sys/class/power_supply/*/status && { echo "On battery - plug in the charger or use -f."; exit 1; }
  ip route show default | grep -q ppp0 && { echo "LTE is the default route (would cut this session) - use -f."; exit 1; }
fi

install_variant() { # stock|patched
  local d=$OUT/debs
  if [ "$1" = stock ]; then
    (cd "$d" && apt-get download "modemmanager=$STOCK_VER" "libmm-glib0=$STOCK_VER") || return 1
    sudo dpkg -i "$d"/modemmanager_${STOCK_VER}_*.deb "$d"/libmm-glib0_${STOCK_VER}_*.deb || return 1
  else
    sudo dpkg -i "$PATCHED_DIR"/libmm-glib0_*jose1_*.deb "$PATCHED_DIR"/modemmanager_*jose1_*.deb || return 1
  fi
  sudo systemctl restart ModemManager
  echo "variant $1: $(dpkg-query -W -f='${Version}' modemmanager)"
}
restore() { dpkg-query -W -f='${Version}' modemmanager | grep -q jose1 || { echo "restoring patched ModemManager"; install_variant patched; }; }
trap 'echo; echo interrupted; restore; exit 130' INT TERM

state() { mmcli -m any --output-keyvalue 2>/dev/null; }
nm_up() { nmcli -t -f DEVICE,STATE dev | grep -qE '^ttyUSB[0-9]+:(connected|pripojené)'; }

one_cycle() { # variant idx
  local start result="" t0 kv fam st retries ready=-1
  sudo nmcli con down "$CON" >/dev/null 2>&1
  "$RAW" disable >/dev/null 2>&1
  start=$(date '+%Y-%m-%d %H:%M:%S'); t0=$SECONDS
  "$RAW" enable >/dev/null 2>&1
  while [ $((SECONDS - t0)) -lt $((READY_TIMEOUT + 20)) ]; do
    kv=$(state)
    if [ -n "$kv" ]; then
      st=$(awk -F': ' '/^modem.generic.state +:/{print $2; exit}' <<<"$kv")
      grep -qE 'supported-ip-families +: --' <<<"$kv" && fam=empty || fam=ok
      [ "$st" = failed ] && break
      if [ "$fam" = ok ] && nm_up; then ready=$((SECONDS - t0)); break; fi
    fi
    sleep 3
  done
  kv=$(state)
  if [ $ready -ge 0 ]; then result=OK
  elif [ -z "$kv" ]; then result=FAIL_NO_MODEM
  elif grep -qE 'modem.generic.state +: failed' <<<"$kv"; then result=FAIL_STATE_FAILED
  elif grep -qE 'supported-ip-families +: --' <<<"$kv"; then result=FAIL_EMPTY_IP_FAMILIES
  else result=FAIL_NM_NOT_CONNECTED; fi
  retries=$(journalctl -u ModemManager --since "$start" --no-pager -q 2>/dev/null | grep -c "couldn.t load supported IP families, retrying")
  echo "$1,$2,$result,$ready,$retries,$start" >> "$CSV"
  printf '%-8s #%-3s %-26s ready=%ss retries=%s\n' "$1" "$2" "$result" "$ready" "$retries"
}

run_variant() {
  install_variant "$1" || { echo "install of $1 failed"; restore; exit 1; }
  local i; for i in $(seq "$N"); do one_cycle "$1" "$i"; done
}

summary() {
  echo; echo "== summary ($CSV) =="
  awk -F, 'NR>1{n[$1]++; if($3=="OK"){ok[$1]++; s[$1]+=$4} else f[$1" "$3]++; r[$1]+=$5; if($5>0)rc[$1]++}
    END{for(v in n){printf "%-8s cycles=%d ok=%d (%.0f%%) avg_ready=%.0fs cycles_with_retry=%d total_retries=%d\n",
        v,n[v],ok[v],100*ok[v]/n[v],(ok[v]?s[v]/ok[v]:0),rc[v],r[v]}
      for(k in f) printf "  %s: %d\n",k,f[k]}' "$CSV"
  echo "Note: SIM not inserted / unknown-capabilities and power brownouts are separate issues; check journalctl for them."
}

echo "variant,cycle,result,ready_s,mm_retries,started" > "$CSV"
case $MODE in
  stock) run_variant stock; restore;;
  patched) run_variant patched;;
  ab) run_variant stock; run_variant patched;;
esac
summary
