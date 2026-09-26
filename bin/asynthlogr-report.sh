#!/usr/bin/env bash
#
# asynthlogr daily report generator. Run manually, or through the
# /asynthlogr-report skill — nothing runs it automatically.
#
# Reads the vault as plain files (like the pending-run hook) and writes
# one note, reports/<YYYY-MM-DD>.md, through basic-memory: a cross-repo
# summary table, then one section per repo and per active thread.
# See docs/reports-design.md.

set -euo pipefail
# Deterministic glob/sort order, and byte-wise matching of the UTF-8
# separators ("—", "×") regardless of the caller's locale.
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage: asynthlogr-report.sh [--today | --date YYYY-MM-DD | --catch-up [--since YYYY-MM-DD]] [--config PATH]

  --today       today's report so far, marked complete: false (the default)
  --date D      (re)generate the report for day D
  --catch-up    generate every finished day that has activity but no report yet
  --since D     with --catch-up: only days on or after D
  --config P    asynthlogr.config.json to use
                (default: $CLAUDE_PROJECT_DIR or the current directory, + /.claude/asynthlogr.config.json)
EOF
  exit 1
}

MODE="today"
DATE=""
SINCE=""
CONFIG="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/asynthlogr.config.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --today) MODE="today"; shift ;;
    --date) MODE="date"; DATE="${2:-}"; shift 2 || usage ;;
    --catch-up) MODE="catch-up"; shift ;;
    --since) SINCE="${2:-}"; shift 2 || usage ;;
    --config) CONFIG="${2:-}"; shift 2 || usage ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

is_date() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; }
[ "$MODE" != "date" ] || is_date "$DATE" || { echo "--date needs YYYY-MM-DD" >&2; exit 1; }
[ -z "$SINCE" ] || is_date "$SINCE" || { echo "--since needs YYYY-MM-DD" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required." >&2; exit 1; }
[ -f "$CONFIG" ] || { echo "ERROR: no asynthlogr config at $CONFIG — run install.sh first." >&2; exit 1; }

VAULT="$(jq -r '.basic_memory_dir // empty' "$CONFIG")"
BM_MODE="$(jq -r '.basic_memory_mode // "cli"' "$CONFIG")"
BM_CONTAINER="$(jq -r '.basic_memory_docker_container // empty' "$CONFIG")"
[ -n "$VAULT" ] && [ -d "$VAULT" ] || { echo "ERROR: vault directory not found: ${VAULT:-<unset>}" >&2; exit 1; }
FAILED_LOG="$VAULT/failed-writes.log"

# Local ISO 8601 with a colon in the offset, e.g. 2026-09-26T11:21:00-07:00.
now_iso() { date +%Y-%m-%dT%H:%M:%S%z | sed 's/\([0-9][0-9]\)$/:\1/'; }
TODAY="$(date +%Y-%m-%d)"

bm() {
  if [ "$BM_MODE" = "docker" ]; then
    docker exec -i "$BM_CONTAINER" basic-memory "$@"
  else
    basic-memory "$@"
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- vault scanning ----
# A day is the literal YYYY-MM-DD prefix of a timestamp, in the writer's
# local time — no time-zone conversion (see docs/reports-design.md).

# Prints "<repo> <thread>" for every thread folder in the vault.
list_threads() {
  local repo_dir thread_dir repo
  for repo_dir in "$VAULT"/*/; do
    [ -d "$repo_dir" ] || continue
    repo="$(basename "$repo_dir")"
    [ "$repo" != "reports" ] || continue
    for thread_dir in "$repo_dir"*/; do
      [ -d "$thread_dir" ] || continue
      echo "$repo $(basename "$thread_dir")"
    done
  done
}

# Failure lines for day $1 ("<ts> | <repo>/<thread> | <type> | <msg>").
failures_on() {
  [ -f "$FAILED_LOG" ] || return 0
  grep "^$1" "$FAILED_LOG" || true
}

# True if <repo>/<thread> has any activity on day $3.
thread_active_on() {
  local repo="$1" thread="$2" d="$3" td="$VAULT/$1/$2"
  grep -q "^## $d" "$td/$thread.md" 2>/dev/null && return 0
  grep -q "^- $d" "$td/agent-use-tracking.md" 2>/dev/null && return 0
  compgen -G "$td/subagents/${d}T*" >/dev/null 2>&1 && return 0
  failures_on "$d" | grep -qF "| $repo/$thread |"
}

# Every day with any activity, one per line, sorted.
activity_dates() {
  local repo thread td
  {
    while read -r repo thread; do
      td="$VAULT/$repo/$thread"
      grep -ho '^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' "$td/$thread.md" 2>/dev/null | cut -c4- || true
      grep -ho '^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' "$td/agent-use-tracking.md" 2>/dev/null | cut -c3- || true
      for run in "$td"/subagents/*/; do
        [ -d "$run" ] || continue
        basename "$run" | grep -o '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' || true
      done
    done < <(list_threads)
    [ ! -f "$FAILED_LOG" ] || grep -o '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' "$FAILED_LOG" || true
  } | sort -u
}

# Entries and open questions from a thread note for day $2. Prints
#   E<TAB><HH:MM><TAB><type><TAB><summary>   one per entry
#   Q<TAB><question>                          one per open question
# Open questions are read from "### Open questions" or its
# "> [!question]" callout form (the optional rendering in
# docs/decision-entry-format.md).
entries_on() {
  [ -f "$1" ] || return 0
  awk -v d="$2" '
    function flush() { if (inentry) printf "E\t%s\t%s\t%s\n", hhmm, type, summary }
    /^## / {
      flush()
      inentry = (index($0, "## " d) == 1)
      inq = 0
      if (inentry) {
        line = substr($0, 4)
        ts = line; sub(/ .*/, "", ts)
        hhmm = substr(ts, 12, 5)
        summary = line
        if (index(summary, " — ") > 0) summary = substr(summary, index(summary, " — ") + length(" — "))
        type = "Entry"
      }
      next
    }
    !inentry { next }
    /^\*\*Type:\*\*/ { type = $0; sub(/^\*\*Type:\*\* */, "", type); next }
    /^### / { inq = ($0 ~ /^### Open questions/) ? 1 : 0; next }
    /^> \[!question\]/ { inq = 2; next }
    /^---[ ]*$/ { inq = 0; next }
    inq == 1 && /^- / { q = $0; sub(/^- /, "", q); printf "Q\t%s\n", q; next }
    inq == 2 && /^> - / { q = $0; sub(/^> - /, "", q); printf "Q\t%s\n", q; next }
    inq == 2 && !/^>/ { inq = 0 }
    END { flush() }
  ' "$1"
}

# The thread's step as of the end of day $2, from its step log:
# "3 (propose)", or empty if no step started on or before that day.
step_as_of() {
  [ -f "$1" ] || return 0
  awk -v d="$2" '
    /^- [0-9][0-9][0-9][0-9]-/ && / — step [0-9]+ \(.*\) started/ {
      if (substr($0, 3, 10) <= d) {
        s = $0; sub(/.* — step /, "", s); sub(/ started.*/, "", s); last = s
      }
    }
    END { print last }
  ' "$1"
}

# Frontmatter value of key $2 in file $1, unquoted.
fm_value() {
  [ -f "$1" ] || return 0
  sed -n "s/^$2: *//p" "$1" 2>/dev/null | head -n1 | sed 's/#.*//' | tr -d "'\"" | sed 's/[[:space:]]*$//'
}

# ---- rendering ----

# Renders day $1's report into $2. Returns 1 if the day had no activity.
render_day() {
  local d="$1" out="$2" repo thread td
  local sections="$WORK/sections" counts="$WORK/counts"
  rm -rf "$sections" "$counts"; mkdir -p "$sections" "$counts"

  # Threads with activity, including ones only named by a failure line
  # (e.g. a run abandoned after its thread's last entry).
  {
    while read -r repo thread; do
      if thread_active_on "$repo" "$thread" "$d"; then echo "$repo $thread"; fi
    done < <(list_threads)
    failures_on "$d" | awk -F' [|] ' '{ split($2, p, "/"); if (p[1] != "" && p[2] != "" && p[1] != "reports") print p[1], p[2] }'
  } | sort -u > "$WORK/active"
  [ -s "$WORK/active" ] || return 1

  local decisions info runs failed pending step
  while read -r repo thread; do
    td="$VAULT/$repo/$thread"
    entries_on "$td/$thread.md" "$d" > "$WORK/entries"
    failures_on "$d" | grep -F "| $repo/$thread |" > "$WORK/failures" || true

    : > "$WORK/runs"
    pending=0
    for run in "$td/subagents/${d}T"*/; do
      [ -d "$run" ] || continue
      name="$(fm_value "$run/agent-use-tracking.md" subagent_name)"
      echo "${name:-unknown}" >> "$WORK/runs"
      case "$(fm_value "$run/agent-use-tracking.md" status)" in
        dispatched|running) pending=$((pending + 1)) ;;
      esac
    done

    decisions="$(awk -F'\t' '$1 == "E" && $3 == "Decision"' "$WORK/entries" | wc -l | tr -d ' ')"
    info="$(awk -F'\t' '$1 == "E" && $3 == "Info"' "$WORK/entries" | wc -l | tr -d ' ')"
    runs="$(wc -l < "$WORK/runs" | tr -d ' ')"
    failed="$(wc -l < "$WORK/failures" | tr -d ' ')"
    echo "$decisions $info $runs $failed" >> "$counts/$repo"

    step="$(step_as_of "$td/agent-use-tracking.md" "$d")"
    {
      echo ""
      if [ -n "$step" ]; then
        echo "### [[$repo/$thread/$thread|$thread]] · step $step"
      else
        echo "### [[$repo/$thread/$thread|$thread]]"
      fi
      if [ "$decisions" -gt 0 ]; then
        echo ""; echo "**Decisions**"
        awk -F'\t' '$1 == "E" && $3 == "Decision" { printf "- %s — %s\n", $2, $4 }' "$WORK/entries"
      fi
      if [ "$info" -gt 0 ]; then
        echo ""; echo "**Info**"
        awk -F'\t' '$1 == "E" && $3 == "Info" { printf "- %s — %s\n", $2, $4 }' "$WORK/entries"
      fi
      other="$(awk -F'\t' '$1 == "E" && $3 != "Decision" && $3 != "Info"' "$WORK/entries")"
      if [ -n "$other" ]; then
        echo ""; echo "**Other entries**"
        echo "$other" | awk -F'\t' '{ printf "- %s — %s (%s)\n", $2, $4, $3 }'
      fi
      if [ "$runs" -gt 0 ]; then
        echo ""
        by_agent="$(sort "$WORK/runs" | uniq -c | awk '{ printf "%s%s ×%s", (NR > 1 ? ", " : ""), $2, $1 }')"
        line="**Subagent runs:** $runs ($by_agent)"
        [ "$pending" -eq 0 ] || line="$line · $pending not finished"
        echo "$line"
      fi
      questions="$(awk -F'\t' '$1 == "Q" { print $2 }' "$WORK/entries")"
      if [ -n "$questions" ]; then
        echo ""
        echo "> [!question]- Open questions raised ($(echo "$questions" | wc -l | tr -d ' '))"
        echo "$questions" | sed 's/^/> - /'
      fi
      if [ "$failed" -gt 0 ]; then
        echo ""; echo "**Failed / abandoned writes**"
        awk -F' [|] ' '{ printf "- %s — %s — %s\n", substr($1, 12, 5), $3, $4 }' "$WORK/failures"
      fi
    } >> "$sections/$repo"
  done < "$WORK/active"

  local repos complete total_failed=0 r
  repos="$(cut -d' ' -f1 "$WORK/active" | sort -u)"
  complete=true
  [ "$d" != "$TODAY" ] || complete=false

  {
    echo "---"
    echo "title: $d"
    echo "type: report"
    echo "report_date: $d"
    echo "generated_at: $(now_iso)"
    echo "complete: $complete"
    echo "repos: [$(echo "$repos" | paste -sd, - | sed 's/,/, /g')]"
    echo "tags: [asynthlogr-report]"
    echo "---"
    echo ""
    echo "# asynthlogr — $d"
    if [ "$complete" = false ]; then
      echo ""
      echo "> [!info] Day still in progress"
      echo "> Generated $(now_iso). Regenerate after the day ends for the full picture."
    fi
    echo ""
    echo "| Repo | Threads | Decisions | Info | Subagent runs | Failed / abandoned |"
    echo "| :--- | --: | --: | --: | --: | --: |"
    for r in $repos; do
      awk -v r="$r" '{ t++; de += $1; in_ += $2; ru += $3; fa += $4 }
        END { printf "| [[#%s]] | %d | %d | %d | %d | %d |\n", r, t, de, in_, ru, fa }' "$counts/$r"
    done
    total_failed="$(cat "$counts"/* | awk '{ s += $4 } END { print s + 0 }')"
    if [ "$total_failed" -gt 0 ]; then
      echo ""
      echo "> [!warning] $total_failed log write(s) failed or were abandoned"
      echo "> Details in the repo sections below; raw lines in \`failed-writes.log\`."
    fi
    for r in $repos; do
      echo ""
      echo "## $r"
      cat "$sections/$r"
    done
  } > "$out"
}

# Writes $2 as reports/<$1>.md through basic-memory, replacing any
# existing report. basic-memory 0.18.x has no --overwrite (it replaces
# by default), so retry without the flag if it's rejected.
write_report() {
  local d="$1" body="$2" err
  if err="$(bm tool write-note --title "$d" --folder reports --project asynthlogr --overwrite < "$body" 2>&1 >/dev/null)"; then
    return 0
  fi
  if echo "$err" | grep -q -- '--overwrite'; then
    if err="$(bm tool write-note --title "$d" --folder reports --project asynthlogr < "$body" 2>&1 >/dev/null)"; then
      return 0
    fi
  fi
  printf '%s | reports/%s | report | %s\n' "$(now_iso)" "$d" "$(echo "$err" | tr '\n' ' ' | cut -c1-200)" >> "$FAILED_LOG"
  echo "ERROR: writing reports/$d.md failed (logged to failed-writes.log): $err" >&2
  return 1
}

# Renders and writes day $1; prints what happened.
report_day() {
  local d="$1" body="$WORK/report-$1.md"
  if ! render_day "$d" "$body"; then
    echo "$d: no activity — no report written."
    return 0
  fi
  write_report "$d" "$body" || return 1
  echo "$d: wrote reports/$d.md ($(grep -c '^## ' "$body") repo(s), $(grep -c '^### ' "$body") thread(s))."
}

case "$MODE" in
  today) report_day "$TODAY" ;;
  date) report_day "$DATE" ;;
  catch-up)
    status=0
    found=0
    while read -r d; do
      [ -n "$d" ] || continue
      [[ "$d" < "$TODAY" ]] || continue
      [ -z "$SINCE" ] || [[ ! "$d" < "$SINCE" ]] || continue
      [ ! -f "$VAULT/reports/$d.md" ] || continue
      found=1
      report_day "$d" || status=1
    done < <(activity_dates)
    [ "$found" -eq 1 ] || echo "Nothing to catch up on: every finished day with activity has a report."
    exit "$status"
    ;;
esac
