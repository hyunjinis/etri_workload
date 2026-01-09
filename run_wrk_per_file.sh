#!/usr/bin/env bash
set -euo pipefail

BASE_URL="http://192.168.0.52:31706"
LIST="paths_20251218184600_tlpr.txt"
OUT="wrk_per_image_20251218184600_please_32.csv"

DUR="10s"
T=32
C=32

SERVER_USER="orin-test"
SERVER_IP="192.168.0.52"
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=3"

# 단위를 ms로 통일하는 함수 (us/ms/s 처리)
to_ms () {
  local v="$1"
  if [[ "$v" == *us ]]; then
    awk -v x="${v%us}" 'BEGIN{printf "%.6f", x/1000.0}'
  elif [[ "$v" == *ms ]]; then
    awk -v x="${v%ms}" 'BEGIN{printf "%.6f", x}'
  elif [[ "$v" == *s ]]; then
    awk -v x="${v%s}" 'BEGIN{printf "%.6f", x*1000.0}'
  else
    echo ""
  fi
}

dur_seconds="${DUR%s}"
if ! [[ "$dur_seconds" =~ ^[0-9]+$ ]]; then
  echo "[ERROR]"
  exit 1
fi

echo "path,avg_latency_ms,p50_latency_ms,requests_per_sec,transfer_per_sec,server_usr,server_sys,server_irq,server_soft,server_idle" > "$OUT"

while IFS= read -r p; do
  [[ -z "$p" ]] && continue

  ssh -n $SSH_OPTS "${SERVER_USER}@${SERVER_IP}" \
    "mpstat -P ALL 2 ${dur_seconds} | awk '/^Average:/ && \$2==\"all\" {print \$3,\$5,\$6,\$7,\$12}'" \
    > /tmp/mpstat_server.$$ 2>/dev/null &
  mpstat_bg_pid=$!

  # wrk 실행
  out=$(WRK_PATH="$p" wrk -t"$T" -c"$C" -d"$DUR" --latency -s one_file.lua "$BASE_URL" 2>&1)

  wait "$mpstat_bg_pid" 2>/dev/null || true
  # Avg latency (Thread Stats 라인의 Latency: "Latency  83.48ms  46.94ms ..."
  avg_raw=$(echo "$out" | awk '/Thread Stats/{f=1} f && $1=="Latency"{print $2; exit}')

  # p50 latency (Latency Distribution 섹션의 "50%   75.09ms")
  p50_raw=$(echo "$out" | awk '$1=="50%"{print $2; exit}')

  # Requests/sec
  rps=$(echo "$out" | awk '/Requests\/sec:/{print $2; exit}')

  # Transfer/sec
  tps=$(echo "$out" | awk '/Transfer\/sec:/{print $2; exit}')

  avg_ms=$(to_ms "$avg_raw")
  p50_ms=$(to_ms "$p50_raw")

  server_usr=""; server_sys=""; server_irq=""; server_soft=""; server_idle=""
  if [[ -s /tmp/mpstat_server.$$ ]]; then
    read -r server_usr server_sys server_irq server_soft server_idle < /tmp/mpstat_server.$$
  fi

  echo "${p},${avg_ms},${p50_ms},${rps},${tps},${server_usr},${server_sys},${server_irq},${server_soft},${server_idle}" >> "$OUT"
  rm -f /tmp/mpstat_server.$$ 2>/dev/null || true
done < "$LIST"

echo "Saved: $OUT"


chmod +x run_wrk_per_file.sh
