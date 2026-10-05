#!/usr/bin/env bash
# Offline integration checks. The fake executable is the only Codex invoked.
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
runner=$root/skills/shepherd/scripts/shepherd-run.sh
(unset SHEPHERD_CAPACITY_WAIT; source "$root/config/shepherd.env"; [[ "$SHEPHERD_CAPACITY_WAIT" == 45 ]])
(unset SHEPHERD_CAPACITY_RETRY_DIV; source "$root/config/shepherd.env"; [[ "$SHEPHERD_CAPACITY_RETRY_DIV" == 2 ]])
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
mkdir -p "$temp/bin" "$temp/repo" "$temp/calls" "$temp/state"
export PATH="$temp/bin:$PATH" SHEPHERD_CONFIG="$root/config/shepherd.env"
export FAKE_CALLS="$temp/calls" FAKE_REPO="$temp/repo"
export SHEPHERD_STATE_DIR="$temp/state" SHEPHERD_TIMEOUT=8 SHEPHERD_TIMEOUT_MAX=8
export SHEPHERD_ESCALATED_TIMEOUT=10 SHEPHERD_ESCALATED_TIMEOUT_MAX=10
export SHEPHERD_RESUME_TIMEOUT=3 SHEPHERD_KILL_AFTER=1 SHEPHERD_CAPACITY_WAIT=0
export SHEPHERD_CAPACITY_RETRY_DIV=2
export SHEPHERD_SOL_LIMIT=2 SHEPHERD_SLOT_WAIT=8
export SHEPHERD_READ_SOFT_PERCENT=85 SHEPHERD_WRITE_SOFT_PERCENT=80
export SHEPHERD_TERSE=full SHEPHERD_DISABLE_MULTI_AGENT=1 POST_WRITE_CHECK=''
export SHEPHERD_LUNA_MAX_EFFORT=max
export SHEPHERD_SOL_MAX_EFFORT=xhigh
export SHEPHERD_RESERVE_MAX_EFFORT=max SHEPHERD_CRITICAL_TIER=sol SHEPHERD_CRITICAL_MIN_EFFORT=high
export SHEPHERD_MODEL_LUNA=fake-luna SHEPHERD_MODEL_SOL=fake-sol
export SHEPHERD_MODEL_ASTRA=fake-astra SHEPHERD_MODEL_RESERVE=fake-reserve
unset SHEPHERD_SCOPE_RULES SHEPHERD_REPORT_FORMAT
printf 'Perform the named task.\n' > "$temp/task.txt"
git -C "$temp/repo" init -q
printf 'initial\n' > "$temp/repo/tracked.txt"
git -C "$temp/repo" add tracked.txt
git -C "$temp/repo" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
export FAKE_TIMEOUT="$(command -v timeout)"
cat > "$temp/bin/timeout" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_CALLS/$$.timeout"
exec "$FAKE_TIMEOUT" "$@"
FAKE
chmod +x "$temp/bin/timeout"
cat > "$temp/bin/codex" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$FAKE_CALLS/$$.args"
resume=0 report=''
[[ "${2:-}" != resume ]] || resume=1
while (( $# )); do
  if [[ "$1" == -o ]]; then report=$2; shift; fi
  shift
done
cat > "$FAKE_CALLS/$$.prompt"
case "$FAKE_CASE" in *-no-session) ;; *) echo 'session id: fake-session';; esac
echo 'tokens used'
echo '1,234'
if [[ "$FAKE_CASE" == interrupt || "$FAKE_CASE" == exit-child || ( "$FAKE_CASE" == interrupt-resume && "$resume" == 1 ) ]]; then
  sleep 30 &
  descendant=$!
  printf '%s %s %s\n' "$PPID" "$$" "$descendant" > "$FAKE_CALLS/live"
  if [[ "$FAKE_CASE" != exit-child ]]; then
    trap 'wait "$descendant" 2>/dev/null || true; exit 0' TERM INT
    wait "$descendant"
  fi
fi
if (( resume )); then
  case "$FAKE_CASE" in
    capacity) echo 'ERROR: model is at capacity'; exit 1;;
    capacity-quota) echo 'ERROR: usage limit reached'; exit 1;;
  esac
  printf 'STATUS: partial\nRecovered report\n' > "$report"
  exit 0
fi
case "$FAKE_CASE" in
  timeout) sleep 3;;
  timeout-no-session) exit 124;;
  quota) echo 'ERROR: quota exhausted'; exit 1;;
  capacity|capacity-ok|capacity-quota|capacity-no-session|interrupt-resume) echo 'ERROR: model is at capacity'; exit 1;;
  quota-text) echo 'Example code: rate_limit and quota'; exit 1;;
  write) printf 'changed\n' >> "$FAKE_REPO/tracked.txt";;
  hold)
    exec 8>"$FAKE_CALLS/count.lock"
    flock 8
    read -r active peak < "$FAKE_CALLS/count"
    active=$((active + 1))
    (( peak >= active )) || peak=$active
    printf '%s %s\n' "$active" "$peak" > "$FAKE_CALLS/count"
    flock -u 8
    trap 'flock 8; read -r active peak < "$FAKE_CALLS/count"; printf "%s %s\n" "$((active - 1))" "$peak" > "$FAKE_CALLS/count"; flock -u 8' EXIT
    sleep 1
    ;;
esac
printf 'STATUS: complete\nFake report\n' > "$report"
FAKE
chmod +x "$temp/bin/codex"
[[ "$(command -v codex)" == "$temp/bin/codex" ]]
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect() {
  local expected=$1 scenario=$2 tier=$3 effort=$4 mode=$5 rc=0
  shift 5
  FAKE_CASE=$scenario bash "$runner" "$tier" "$effort" "$mode" "$temp/task.txt" "$temp/repo" "$@" > "$temp/output" 2>&1 || rc=$?
  [[ "$rc" == "$expected" ]] || { tail -n 8 "$temp/output" >&2; fail "$scenario $tier $effort expected $expected, got $rc"; }
}
contains() { grep -qF -- "$1" "$temp/output" || fail "missing output: $1"; }
for effort in low medium high; do expect 0 ok luna "$effort" read; done
for effort in medium high; do expect 0 ok sol "$effort" read; done
for effort in low medium high xhigh max; do expect 0 ok reserve "$effort" read; done
expect 0 ok luna max read --escalate
expect 0 ok sol xhigh read --escalate
expect 0 ok astra low read --escalate
expect 0 ok sol high read --critical
expect 0 ok sol xhigh read --critical --escalate
for effort in low max xhigh; do expect 2 ok sol "$effort" read; done
expect 2 ok sol max read --escalate
expect 2 ok luna xhigh read
expect 2 ok astra low read
expect 2 ok astra high read --escalate
contains 'astra requires low effort; got high'
expect 2 ok sol medium read --critical
expect 2 ok luna high read --critical
expect 2 ok unknown low read
expect 2 ok luna unknown read
expect 2 ok luna low unknown
expect 2 ok luna low read --unknown
SHEPHERD_CRITICAL_TIER=luna SHEPHERD_CRITICAL_MIN_EFFORT=medium expect 0 ok luna medium read --critical
SHEPHERD_SOL_MAX_EFFORT=max expect 2 ok sol max read --escalate
SHEPHERD_SOL_MAX_EFFORT=high expect 2 ok sol xhigh read --escalate
SHEPHERD_LUNA_MAX_EFFORT=high expect 2 ok luna max read --escalate
SHEPHERD_SOL_MAX_EFFORT=xhigh expect 2 ok sol xhigh read
SHEPHERD_LUNA_MAX_EFFORT=max expect 2 ok luna max read
SHEPHERD_SOL_MAX_EFFORT=medium expect 0 ok sol high read
SHEPHERD_LUNA_MAX_EFFORT=medium expect 0 ok luna high read
SHEPHERD_CAPACITY_RETRY_DIV=0 expect 2 ok luna low read
SHEPHERD_TIMEOUT=invalid expect 2 ok luna low read
SHEPHERD_READ_SOFT_PERCENT=101 expect 2 ok luna low read

expect 0 ok luna low read
contains 'sandbox=read-only'
contains '== tokens: 1234'
contains '== log:'
prompts=("$FAKE_CALLS"/*.prompt)
grep -qF '$caveman full' "${prompts[@]}" || fail 'terse prefix missing'
for heading in 'STATUS:' 'CHANGED FILES:' 'CRITERIA:' 'CHECKS RUN:' 'OPEN ITEMS / BLOCKERS:' 'SUGGESTIONS (not applied):'; do
  grep -qF "$heading" "${prompts[@]}" || fail "missing report heading: $heading"
done
grep -qF 'Prove a bug root cause with file:line' "${prompts[@]}" || fail 'scope rules missing'
grep -qF 'multi_agent' "$FAKE_CALLS"/*.args || fail 'nested agents not disabled'

# Isolate captures to verify options can be disabled or configured.
mkdir "$temp/options"
FAKE_CALLS="$temp/options" SHEPHERD_TERSE=off SHEPHERD_DISABLE_MULTI_AGENT=0 expect 0 ok luna low read
if grep -qF '$caveman' "$temp/options"/*.prompt; then fail 'terse off ignored'; fi
if grep -qF 'multi_agent' "$temp/options"/*.args; then fail 'disable setting ignored'; fi
mkdir "$temp/custom"
FAKE_CALLS="$temp/custom" SHEPHERD_TERSE=lite SHEPHERD_SCOPE_RULES='Custom scope rule' SHEPHERD_REPORT_FORMAT='Custom report format' expect 0 ok luna low read
grep -qF '$caveman lite' "$temp/custom"/*.prompt || fail 'terse level ignored'
grep -qF 'Custom scope rule' "$temp/custom"/*.prompt || fail 'scope setting ignored'
grep -qF 'Custom report format' "$temp/custom"/*.prompt || fail 'report setting ignored'

mkdir "$temp/deadlines"
FAKE_CALLS="$temp/deadlines" SHEPHERD_TIMEOUT=100 SHEPHERD_TIMEOUT_MAX=4 expect 0 ok luna low read
grep -qF 'Hard limit: 4 seconds;' "$temp/deadlines"/*.prompt || fail 'timeout ceiling ignored'
awk '/start epoch:/ { split($0,a,"start epoch: "); split(a[2],b,";"); split($0,c,"after epoch "); split(c[2],d,"."); if (d[1]-b[1] != 3) exit 1; found=1 } END { if (!found) exit 1 }' "$temp/deadlines"/*.prompt || fail 'read soft limit incorrect'
mkdir "$temp/escalated"
FAKE_CALLS="$temp/escalated" SHEPHERD_ESCALATED_TIMEOUT=100 SHEPHERD_ESCALATED_TIMEOUT_MAX=5 expect 0 ok luna max write --escalate
grep -qF 'Hard limit: 5 seconds;' "$temp/escalated"/*.prompt || fail 'escalated ceiling ignored'
awk '/start epoch:/ { split($0,a,"start epoch: "); split(a[2],b,";"); split($0,c,"after epoch "); split(c[2],d,"."); if (d[1]-b[1] != 4) exit 1; found=1 } END { if (!found) exit 1 }' "$temp/escalated"/*.prompt || fail 'write soft limit incorrect'

mkdir "$temp/recovery"
FAKE_CALLS="$temp/recovery" SHEPHERD_TIMEOUT=1 expect 124 timeout luna low read
contains 'RECOVERY REPORT: resume exit=0'
contains 'Recovered report'
contains '== tokens: 2468'
grep -qF 'resume' "$temp/recovery"/*.args || fail 'timeout did not resume'
grep -qF 'sandbox_mode="read-only"' "$temp/recovery"/*.args || fail 'recovery sandbox incorrect'
expect 124 timeout-no-session luna low read
if grep -qF 'RECOVERY REPORT:' "$temp/output"; then fail 'resume without session'; fi
expect 75 quota luna low read
contains 'CODEX_QUOTA_EXHAUSTED'
expect 1 quota-text luna low read
mkdir "$temp/capacity"
FAKE_CALLS="$temp/capacity" expect 76 capacity luna low read
contains 'CODEX_CAPACITY'
calls=("$temp/capacity"/*.args)
[[ ${#calls[@]} == 2 ]] || fail 'capacity must resume exactly once'
expect 0 capacity-ok luna low read
expect 75 capacity-quota luna low read
expect 76 capacity-no-session luna low read

# Capacity resumes use the clamped run limit, not the report recovery timeout.
for settings in 'normal 420 420 210' 'escalated 600 600 300' 'clamped 600 12 6'; do
  read -r kind duration ceiling expected < <(printf '%s\n' "$settings")
  mkdir "$temp/retry-$kind"
  flags=()
  [[ "$kind" != escalated ]] || flags=(--escalate)
  FAKE_CALLS="$temp/retry-$kind" SHEPHERD_TIMEOUT="$duration" SHEPHERD_TIMEOUT_MAX="$ceiling" SHEPHERD_ESCALATED_TIMEOUT="$duration" SHEPHERD_ESCALATED_TIMEOUT_MAX="$ceiling" expect 0 capacity-ok luna low read "${flags[@]}"
  captures=("$temp/retry-$kind"/*.timeout)
  [[ ${#captures[@]} == 2 ]] || fail 'capacity timeout captures missing'
  grep -lFx resume "${captures[@]}" | xargs awk -v expected="$expected" 'NR == 2 { if ($0 != expected) exit 1 }' || fail "$kind capacity resume limit incorrect"
done
mkdir "$temp/retry-div"
FAKE_CALLS="$temp/retry-div" SHEPHERD_CAPACITY_RETRY_DIV=4 expect 0 capacity-ok luna low read
grep -lFx resume "$temp/retry-div"/*.timeout | xargs awk 'NR == 2 { if ($0 != 2) exit 1 }' || fail 'capacity divisor ignored'

# Signal the wrapper alone; its trap must stop both Codex and its descendant.
for spec in 'TERM interrupt 143' 'INT interrupt 130' 'TERM interrupt-resume 143' 'EXIT exit-child 0'; do
  read -r signal scenario expected < <(printf '%s\n' "$spec")
  captures="$temp/signal-$signal-$scenario"
  mkdir "$captures"
  set -m
  FAKE_CALLS="$captures" FAKE_CASE="$scenario" SHEPHERD_SOL_LIMIT=1 bash "$runner" sol high read "$temp/task.txt" "$temp/repo" > "$temp/signal-output" 2>&1 &
  wrapper=$!
  set +m
  for ((attempt=0; attempt<100; attempt++)); do
    [[ ! -s "$captures/live" ]] || break
    sleep 0.05
  done
  [[ -s "$captures/live" ]] || fail 'fake Codex did not start'
  [[ "$signal" == EXIT ]] || kill -"$signal" "$wrapper"
  rc=0
  wait "$wrapper" || rc=$?
  [[ "$rc" == "$expected" ]] || fail "$signal wrapper exit=$rc"
  read -r timeout_pid codex_pid descendant < "$captures/live"
  for pid in "$timeout_pid" "$codex_pid" "$descendant"; do
    process_state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
    [[ -z "$process_state" || "$process_state" == Z* ]] || fail "$signal leaked process $pid"
  done
  (exec 6>"$SHEPHERD_STATE_DIR/sol.1.lock"; flock -n 6) || fail "$signal leaked sol lock"
  SHEPHERD_SOL_LIMIT=1 SHEPHERD_SLOT_WAIT=0 expect 0 ok sol high read
done

POST_WRITE_CHECK='printf checked > post-check.txt' expect 0 write luna low write
contains 'sandbox=workspace-write'
contains 'git diff --stat'
contains 'tracked.txt'
contains 'POST_WRITE_CHECK exit=0'
[[ -f "$temp/repo/post-check.txt" ]] || fail 'post-write command not executed in workdir'
expect 0 write luna low write
if grep -qF 'POST_WRITE_CHECK exit=' "$temp/output"; then fail 'empty post-write check not skipped'; fi
POST_WRITE_CHECK='exit 9' expect 9 write luna low write
POST_WRITE_CHECK='exit 9' expect 75 quota luna low write
POST_WRITE_CHECK='exit 9' expect 0 ok luna low read

printf '0 0\n' > "$FAKE_CALLS/count"
pids=()
for job in 1 2 3 4; do
  FAKE_CASE=hold bash "$runner" sol medium read "$temp/task.txt" "$temp/repo" > "$temp/parallel-$job" 2>&1 &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || fail 'queued sol failed'; done
read -r active peak < "$FAKE_CALLS/count"
[[ "$active" == 0 && "$peak" == 2 ]] || fail "sol limit incorrect: active=$active peak=$peak"
printf '0 0\n' > "$FAKE_CALLS/count"
pids=()
for job in 1 2 3; do
  FAKE_CASE=hold SHEPHERD_SOL_LIMIT=1 bash "$runner" sol medium read "$temp/task.txt" "$temp/repo" > "$temp/single-$job" 2>&1 &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || fail 'single-slot sol failed'; done
read -r active peak < "$FAKE_CALLS/count"
[[ "$active" == 0 && "$peak" == 1 ]] || fail "configured sol limit incorrect: active=$active peak=$peak"
exec 7>"$SHEPHERD_STATE_DIR/sol.1.lock"
flock 7
SHEPHERD_SOL_LIMIT=1 SHEPHERD_SLOT_WAIT=0 expect 77 ok sol medium read
contains 'CODEX_SLOT_TIMEOUT'
flock -u 7
exec 7>&-
printf 'ALL OK\n'
