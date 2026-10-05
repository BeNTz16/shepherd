#!/usr/bin/env bash
# Delegate one bounded task. Never run nested agents or bypass the sandbox.
set -euo pipefail
usage() {
  echo 'Usage: shepherd-run.sh <luna|sol|astra|reserve> <low|medium|high|xhigh|max> <read|write> <prompt-file> [workdir] [--escalate] [--critical]' >&2
}
fail() { echo "shepherd: $*" >&2; exit 2; }
[[ $# -ge 4 && $# -le 7 ]] || { usage; exit 2; }
script_dir="$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)"
config="${SHEPHERD_CONFIG:-$script_dir/../../../config/shepherd.env}"
[[ -f "$config" ]] || config="${SHEPHERD_CONFIG:-$script_dir/../config/shepherd.env}"
[[ -r "$config" ]] || fail "cannot read config: $config"
# shellcheck source=/dev/null
source "$config"
tier=$1 effort=$2 mode=$3 prompt_file=$4
shift 4
workdir=$PWD escalated=0 critical=0
if [[ $# -gt 0 && "$1" != --* ]]; then workdir=$1; shift; fi
for argument in "$@"; do
  case "$argument" in
    --escalate) escalated=1;;
    --critical) critical=1;;
    *) fail "unknown argument: $argument";;
  esac
done
[[ -r "$prompt_file" && -f "$prompt_file" ]] || fail 'prompt file is not readable'
prompt_file="$(realpath -- "$prompt_file")"
[[ -d "$workdir" ]] || fail 'workdir is not a directory'
workdir="$(cd -- "$workdir" && pwd -P)"
rank() {
  case "$1" in low) echo 1;; medium) echo 2;; high) echo 3;; xhigh) echo 4;; max) echo 5;; *) return 1;; esac
}
effort_rank="$(rank "$effort")" || fail "invalid effort: $effort"
case "$tier" in
  luna)
    model=$SHEPHERD_MODEL_LUNA cap=high
    (( ! escalated )) || cap=$SHEPHERD_LUNA_MAX_EFFORT
    ;;
  sol)
    model=$SHEPHERD_MODEL_SOL cap=high
    [[ "$effort" != low && "$effort" != max ]] || fail 'sol permits medium, high, or escalated xhigh'
    (( ! escalated )) || cap=$SHEPHERD_SOL_MAX_EFFORT
    ;;
  astra)
    model=$SHEPHERD_MODEL_ASTRA cap=low
    (( escalated )) || fail 'astra requires --escalate'
    [[ "$effort" == low ]] || fail "astra requires low effort; got $effort"
    ;;
  reserve) model=$SHEPHERD_MODEL_RESERVE cap=$SHEPHERD_RESERVE_MAX_EFFORT;;
  *) fail "invalid tier: $tier";;
esac
cap_rank="$(rank "$cap")" || fail "invalid configured effort ceiling: $cap"
(( effort_rank <= cap_rank )) || fail "effort $effort exceeds $tier ceiling $cap"
if (( critical )); then
  critical_rank="$(rank "$SHEPHERD_CRITICAL_MIN_EFFORT")" || fail 'invalid critical effort'
  [[ "$tier" == "$SHEPHERD_CRITICAL_TIER" ]] && (( effort_rank >= critical_rank )) || fail "critical tasks require $SHEPHERD_CRITICAL_TIER at least $SHEPHERD_CRITICAL_MIN_EFFORT"
fi
[[ -n "$model" ]] || fail 'model must not be empty'
case "$SHEPHERD_TERSE" in off|lite|full|ultra|wenyan-lite|wenyan-full|wenyan-ultra) ;; *) fail 'invalid SHEPHERD_TERSE';; esac
[[ "$SHEPHERD_DISABLE_MULTI_AGENT" == 0 || "$SHEPHERD_DISABLE_MULTI_AGENT" == 1 ]] || fail 'SHEPHERD_DISABLE_MULTI_AGENT must be 0 or 1'
agent_flags=()
[[ "$SHEPHERD_DISABLE_MULTI_AGENT" == 0 ]] || agent_flags=(--disable multi_agent)
case "$mode" in read) sandbox=read-only;; write) sandbox=workspace-write;; *) fail 'mode must be read or write';; esac
for variable in SHEPHERD_TIMEOUT SHEPHERD_ESCALATED_TIMEOUT SHEPHERD_TIMEOUT_MAX SHEPHERD_ESCALATED_TIMEOUT_MAX SHEPHERD_RESUME_TIMEOUT SHEPHERD_KILL_AFTER SHEPHERD_CAPACITY_RETRY_DIV SHEPHERD_SOL_LIMIT SHEPHERD_READ_SOFT_PERCENT SHEPHERD_WRITE_SOFT_PERCENT; do
  [[ ${!variable} =~ ^[1-9][0-9]*$ ]] || fail "$variable must be a positive integer"
done
for variable in SHEPHERD_SLOT_WAIT SHEPHERD_CAPACITY_WAIT; do
  [[ ${!variable} =~ ^(0|[1-9][0-9]*)$ ]] || fail "$variable must be a nonnegative integer"
done
(( SHEPHERD_READ_SOFT_PERCENT <= 100 && SHEPHERD_WRITE_SOFT_PERCENT <= 100 )) || fail 'soft percentages must be at most 100'
for executable in codex timeout flock setsid; do command -v "$executable" >/dev/null || { echo "Missing dependency: $executable" >&2; exit 127; }; done
limit=$SHEPHERD_TIMEOUT ceiling=$SHEPHERD_TIMEOUT_MAX
if (( escalated )); then limit=$SHEPHERD_ESCALATED_TIMEOUT; ceiling=$SHEPHERD_ESCALATED_TIMEOUT_MAX; fi
(( limit <= ceiling )) || limit=$ceiling
state="${SHEPHERD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/shepherd}"
umask 077
mkdir -p -- "$state"
job="$(mktemp -d "$state/$tier.XXXXXX")"
log=$job/run.log last=$job/report.md
child_pid=''
stop_child() {
  if [[ -n "$child_pid" ]]; then
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    local deadline=$((SECONDS + SHEPHERD_KILL_AFTER))
    while kill -0 -- "-$child_pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.1; done
    kill -KILL -- "-$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  child_pid=''
}
cleanup() {
  trap - EXIT INT TERM
  stop_child
  exec 9>&-
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
if [[ "$tier" == sol ]]; then
  wait_start=$SECONDS
  while :; do
    acquired=0
    for ((slot=1; slot<=SHEPHERD_SOL_LIMIT; slot++)); do
      exec 9>"$state/sol.$slot.lock"
      if flock -n 9; then acquired=1; break; fi
      exec 9>&-
    done
    (( ! acquired )) || break
    if (( SECONDS - wait_start >= SHEPHERD_SLOT_WAIT )); then
      echo 'CODEX_SLOT_TIMEOUT: sol concurrency limit reached' >&2
      exit 77
    fi
    sleep 1
  done
fi
start=$(date +%s)
soft_percent=$SHEPHERD_WRITE_SOFT_PERCENT
[[ "$mode" != read ]] || soft_percent=$SHEPHERD_READ_SOFT_PERCENT
soft=$((start + limit * soft_percent / 100))
{
  if [[ "$SHEPHERD_TERSE" != off ]]; then printf '$caveman %s\n\n' "$SHEPHERD_TERSE"; fi
  printf '%s\n' "$SHEPHERD_SCOPE_RULES"
  printf 'Hard limit: %s seconds; start epoch: %s; stop starting new reads or writes after epoch %s. Check date +%%s periodically, finish current step, then report remaining subtasks.\n' "$limit" "$start" "$soft"
  while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\n' "$line"; done < "$prompt_file"
  printf '\nRequired final report:\n%s\n' "$SHEPHERD_REPORT_FORMAT"
} > "$job/prompt.txt"
set +e
setsid timeout --kill-after="$SHEPHERD_KILL_AFTER" "$limit" codex exec -m "$model" \
  -c "model_reasoning_effort=\"$effort\"" "${agent_flags[@]}" --skip-git-repo-check \
  -s "$sandbox" -C "$workdir" --color never -o "$last" - < "$job/prompt.txt" > "$log" 2>&1 9>&- &
child_pid=$!
wait "$child_pid"
rc=$?
stop_child
set -e
sid="$(sed -n 's/^session id: *//p' "$log" | head -n 1)"
quota() { grep -qiE '^ERROR[: ].*(usage limit|rate.?limit|quota|429|too many requests|insufficient)' "$1"; }
capacity() { grep -qiE '^ERROR[: ].*at capacity' "$1"; }
resume() {
  local resume_sandbox=$1 resume_effort=$2 message=$3 resume_limit=${4:-$SHEPHERD_RESUME_TIMEOUT}
  set +e
  setsid timeout --kill-after="$SHEPHERD_KILL_AFTER" "$resume_limit" \
    codex exec resume -m "$model" -c "model_reasoning_effort=\"$resume_effort\"" \
    "${agent_flags[@]}" --skip-git-repo-check -C "$workdir" \
    -c "sandbox_mode=\"$resume_sandbox\"" -o "$last" "$sid" - <<< "$message" > "$job/resume.log" 2>&1 9>&- &
  child_pid=$!
  wait "$child_pid"
  resume_rc=$?
  stop_child
  set -e
}
if (( rc == 124 || rc == 137 )); then
  echo "CODEX_TIMEOUT: model=$model limit=${limit}s; split remaining work"
  if [[ -n "$sid" ]]; then
    resume read-only low 'Time expired. Do not call tools or change files. Return the required final report with STATUS: partial and remaining bounded subtasks.'
    echo "RECOVERY REPORT: resume exit=$resume_rc"
  fi
  rc=124
elif (( rc != 0 )) && quota "$log"; then
  echo "CODEX_QUOTA_EXHAUSTED: model=$model"
  rc=75
elif (( rc != 0 )) && capacity "$log"; then
  if [[ -n "$sid" ]]; then
    echo "CODEX_CAPACITY: waiting ${SHEPHERD_CAPACITY_WAIT}s before one resume"
    sleep "$SHEPHERD_CAPACITY_WAIT"
    retry_limit=$((limit / SHEPHERD_CAPACITY_RETRY_DIV))
    (( retry_limit > 0 )) || retry_limit=1
    resume "$sandbox" "$effort" 'Capacity interrupted this task. Continue from existing work; return the required final report.' "$retry_limit"
    rc=$resume_rc
    if (( rc != 0 )) && quota "$job/resume.log"; then rc=75
    elif (( rc != 0 )) && capacity "$job/resume.log"; then rc=76
    elif (( rc == 137 )); then rc=124; fi
  else rc=76; fi
fi
(( rc != 76 )) || echo "CODEX_CAPACITY: model=$model; retry exhausted"
echo "== model=$model effort=$effort sandbox=$sandbox exit=$rc"
echo "== log: $log"
token_logs=("$log")
[[ ! -f "$job/resume.log" ]] || token_logs+=("$job/resume.log")
tokens="$(awk '/^tokens used$/ { if (getline > 0) { gsub(/,/, ""); if ($0 ~ /^[0-9]+$/) { total += $0; seen=1 } } } END { if (seen) print total; else print "?" }' "${token_logs[@]}")"
echo "== tokens: ${tokens:-?}"
if [[ -s "$last" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do printf '%s\n' "$line"; done < "$last"
else tail -n 20 "$log"; fi
if [[ "$mode" == write ]]; then
  echo '== git diff --stat (working tree, including prior changes):'
  git -C "$workdir" diff --stat 2>/dev/null || true
  if [[ -n "$POST_WRITE_CHECK" ]]; then
    check_rc=0
    (cd -- "$workdir" && bash -c "$POST_WRITE_CHECK") || check_rc=$?
    echo "== POST_WRITE_CHECK exit=$check_rc"
    (( rc != 0 || check_rc == 0 )) || rc=$check_rc
  fi
fi
exit "$rc"
