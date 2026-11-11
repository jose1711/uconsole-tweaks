#!/bin/bash
# xfce4-genmon: data usage over ppp0 (vnstat)
IF=ppp0
LIMIT_GB=4      # data plan size (Radosť 4 GB)
CYCLE_DAY=14    # day of month the plan renews (set to match your operator)
export LANG=C LC_ALL=C

json=$(vnstat --json a -i "$IF" 2>/dev/null)
if [ -z "$json" ] || ! jq -e '.interfaces[0]' <<<"$json" >/dev/null 2>&1; then
    printf "<txt>LTE: –</txt><tool>vnstat: žiadne dáta pre %s</tool>" "$IF"
    exit 0
fi

# --- a single jq call: all numbers in bytes ---
read -r m_rx m_tx t_rx t_tx mday < <(jq -r --arg now "$(date +%Y-%m-%d)" '
  .interfaces[0].traffic as $t
  | ($t.month | last) as $m
  | ($t.day | map({d:(.date|"\(.year)-\("0\(.month)"[-2:])-\("0\(.day)"[-2:])"), rx, tx})) as $days
  | ($days | map(select(.d==$now)) | first // {rx:0,tx:0}) as $td
  | [$m.rx,$m.tx,$td.rx,$td.tx,($now[8:10]|tonumber)] | map(tostring) | join(" ")' <<<"$json")
dim=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%d); dim=$((10#$dim))

hum() { awk -v b="$1" 'BEGIN{
  if(b>=1073741824) printf "%.2f GB", b/1073741824;
  else if(b>=1048576) printf "%.0f MB", b/1048576;
  else printf "%.0f kB", b/1024 }'; }

spark() { # input: one number per line
  awk 'BEGIN{split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █",c," ")}
       {v[NR]=$1; if($1>m)m=$1}
       END{for(i=1;i<=NR;i++){k=(m>0)?int(v[i]/m*7)+1:1; if(k>8)k=8; printf "%s", c[k]} print ""}'; }

t_tot=$((t_rx + t_tx))

# last 7 calendar days (vnstat omits days without traffic)
declare -A dtot
while read -r d b; do dtot[$d]=$b; done < <(jq -r '.interfaces[0].traffic.day[] | "\(.date.year)-\("0\(.date.month)"[-2:])-\("0\(.date.day)"[-2:]) \(.rx+.tx)"' <<<"$json")
g7=$(for i in 6 5 4 3 2 1 0; do echo "${dtot[$(date -d "-$i day" +%F)]:-0}"; done | spark)
y_tot=${dtot[$(date -d yesterday +%F)]:-0}

# total for the current plan period (since CYCLE_DAY)
cd_=$(printf %02d "$CYCLE_DAY")
if [ "$(date +%d)" -ge "$CYCLE_DAY" ]; then start=$(date +%Y-%m-)$cd_; else start=$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m-)$cd_; fi
end=$(date -d "$start +1 month" +%F)
m_tot=0
for d in "${!dtot[@]}"; do [[ ! "$d" < "$start" && "$d" < "$end" ]] && m_tot=$((m_tot + dtot[$d])); done
elapsed=$(( ( $(date +%s) - $(date -d "$start" +%s) ) / 86400 + 1 ))
plen=$(( ( $(date -d "$end" +%s) - $(date -d "$start" +%s) ) / 86400 ))
left=$((plen - elapsed))
proj=$(awk -v t="$m_tot" -v d="$elapsed" -v n="$plen" 'BEGIN{printf "%d", t/d*n}')
limit=$((LIMIT_GB * 1073741824))
pct=$((m_tot * 100 / limit))
rest=$((limit - m_tot)); [ "$rest" -lt 0 ] && rest=0
g24=$(jq -r '.interfaces[0].traffic.hour[-24:][] | (.rx+.tx)' <<<"$json" | spark)
peak_d=; peak_b=0
for d in "${!dtot[@]}"; do [ "${dtot[$d]}" -gt "$peak_b" ] && { peak_b=${dtot[$d]}; peak_d=$d; }; done

# colour by % of the limit (>=60 % orange, >=85 % red)
col=green
[ "$pct" -ge 60 ] && col=orange
[ "$pct" -ge 85 ] && col=red

printf "<txt>%s <span fgcolor='%s'>%s%%</span> %s</txt>" "$(hum "$m_tot")" "$col" "$pct" "$g7"
printf "<txtclick>xterm -e 'vnstat -i %s -d 10; vnstat -i %s -h 12; read -n1 -s -p \"...\"'</txtclick>" "$IF" "$IF"
printf "<tool>Obdobie:  %s z %s GB (%s %%), zostáva %s\n          (↓%s ↑%s), %s dní do obnovy\nPredpoveď: ~%s\nDnes:     %s  (↓%s ↑%s)\nVčera:    %s\nRekord:   %s (%s)\n\nPosl. 7 dní:  %s\nPosl. 24 h:   %s</tool>" \
  "$(hum "$m_tot")" "$LIMIT_GB" "$pct" "$(hum "$rest")" "$(hum "$m_rx")" "$(hum "$m_tx")" "$left" "$(hum "$proj")" \
  "$(hum "$t_tot")" "$(hum "$t_rx")" "$(hum "$t_tx")" "$(hum "$y_tot")" \
  "$(hum "$peak_b")" "$peak_d" "$g7" "$g24"
