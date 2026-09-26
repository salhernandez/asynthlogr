---
name: asynthlogr-report
description: Generate the asynthlogr daily report (reports/<YYYY-MM-DD>.md in the basic-memory vault) — a cross-repo summary with one section per repo and thread. Run manually as /asynthlogr-report [--today | --date YYYY-MM-DD | --catch-up [--since YYYY-MM-DD]].
disable-model-invocation: true
---

# asynthlogr-report

Run the report generator with Bash, passing the arguments through
unchanged:

```bash
bash .claude/asynthlogr/bin/asynthlogr-report.sh $ARGUMENTS
```

- No arguments: today's report so far, marked `complete: false`.
- `--date YYYY-MM-DD`: (re)generate that day's report.
- `--catch-up [--since YYYY-MM-DD]`: generate every finished day that
  has activity but no report yet.

Then tell the user what the script printed: which reports were written
(`reports/<date>.md`) or that a day had no activity. If it failed,
show its error; the failure has already been recorded in
`failed-writes.log`.

Don't write or edit the report note yourself, and don't retry a failed
run. The script is the only writer, so reruns stay deterministic.
