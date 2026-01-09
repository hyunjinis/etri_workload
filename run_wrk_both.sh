LIST_LPR="paths_20251218115336_2lpr.txt"
SERVER_USER_LPR="orin2"
SERVER_IP_LPR="192.168.0.3"

BASE_URL_SPEED="http://192.168.0.3:31558"
LIST_SPEED="paths_20251209195524_2speed.txt"
SERVER_USER_SPEED="orin2"
SERVER_IP_SPEED="192.168.0.3"

to_ms () {
  local v="${1:-}"
  if [[ -z "$v" ]]; then echo ""; return; fi
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
  echo "[ERROR]" >&2
  exit 1
fi

TMP_LPR="$(mktemp /tmp/wrk_lpr_XXXX.csv)"
TMP_SPEED="$(mktemp /tmp/wrk_speed_XXXX.csv)"

HEADER="workload,path,avg_latency_ms,p50_latency_ms,requests_per_sec,transfer_per_sec,server_usr,server_sys,server_irq,server_soft,server_idle"

echo "$HEADER" > "$OUT_ALL"

run_one () {
  local workload="$1"
  local base_url="$2"
  local list="$3"
  local tmp_csv="$4"
  local server_user="$5"
  local server_ip="$6"

  echo "$HEADER" > "$tmp_csv"

  while IFS= read -r p; do
    [[ -z "$p" ]] && continue

    local mpfile="/tmp/mpstat_${workload}_$$"
    rm -f "$mpfile" 2>/dev/null || true

    ssh -n $SSH_OPTS "${server_user}@${server_ip}" \
      "mpstat -P ALL 2 ${dur_seconds} | awk '/^Average:/ && \$2==\"all\" {print \$3,\$5,\$6,\$7,\$12}'" \
      > "$mpfile" 2>/dev/null &
    local mpstat_bg_pid=$!

    # wrk 실행: 실패해도 스크립트 전체가 죽지 않도록 방어
    out=$(WRK_PATH="$p" wrk -t"$T" -c"$C" -d"$DUR" --latency -s one_file.lua "$base_url" 2>&1) || out=""

    wait "$mpstat_bg_pid" 2>/dev/null || true

    avg_raw=$(echo "$out" | awk '/Thread Stats/{f=1} f && $1=="Latency"{print $2; exit}' || true)
    p50_raw=$(echo "$out" | awk '$1=="50%"{print $2; exit}' || true)
    rps=$(echo "$out" | awk '/Requests\/sec:/{print $2; exit}' || true)
    tps=$(echo "$out" | awk '/Transfer\/sec:/{print $2; exit}' || true)

    avg_ms=$(to_ms "$avg_raw")
    p50_ms=$(to_ms "$p50_raw")

    server_usr=""; server_sys=""; server_irq=""; server_soft=""; server_idle=""
    if [[ -s "$mpfile" ]]; then
      read -r server_usr server_sys server_irq server_soft server_idle < "$mpfile" || true
    fi
    rm -f "$mpfile" 2>/dev/null || true

    echo "${workload},${p},${avg_ms},${p50_ms},${rps},${tps},${server_usr},${server_sys},${server_irq},${server_soft},${server_idle}" >> "$tmp_csv"
  done < "$list"
}

merge_loop () {
  while :; do
    {
      echo "$HEADER"
      [[ -f "$TMP_LPR" ]]   && tail -n +2 "$TMP_LPR"   2>/dev/null || true
      [[ -f "$TMP_SPEED" ]] && tail -n +2 "$TMP_SPEED" 2>/dev/null || true
    } > "${OUT_ALL}.tmp" && mv "${OUT_ALL}.tmp" "$OUT_ALL"
    sleep 2
  done
}

pids=()
merge_pid=""

cleaned=0

final_merge () {
  {
    echo "$HEADER"
    [[ -f "$TMP_LPR" ]]   && tail -n +2 "$TMP_LPR"   2>/dev/null || true
    [[ -f "$TMP_SPEED" ]] && tail -n +2 "$TMP_SPEED" 2>/dev/null || true
  } > "${OUT_ALL}.tmp" && mv "${OUT_ALL}.tmp" "$OUT_ALL"
}

cleanup () {
  (( cleaned )) && return
  cleaned=1

  echo
  echo "[MAIN] Stopping..." >&2

  [[ -n "${merge_pid:-}" ]] && kill "$merge_pid" 2>/dev/null || true

  # 워크로드 잡들 정지
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done

  wait 2>/dev/null || true

  # 마지막으로 한 번만 merge
  final_merge

  # TMP는 지우지 않음(보험/디버깅).
  echo "[MAIN] Saved: $OUT_ALL" >&2
  echo "[MAIN] TMP kept: $TMP_LPR , $TMP_SPEED" >&2
}

on_signal () {
  cleanup
  exit 130
}
trap on_signal INT TERM

# merge loop 시작
merge_loop &
merge_pid=$!

# 두 측정 동시 실행
run_one "LPR"   "$BASE_URL_LPR"   "$LIST_LPR"   "$TMP_LPR"   "$SERVER_USER_LPR"   "$SERVER_IP_LPR"   &
pids+=($!)

run_one "SPEED" "$BASE_URL_SPEED" "$LIST_SPEED" "$TMP_SPEED" "$SERVER_USER_SPEED" "$SERVER_IP_SPEED" &
pids+=($!)

wait "${pids[@]}"
cleanup
