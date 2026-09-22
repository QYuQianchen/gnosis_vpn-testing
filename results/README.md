# results/

The small, durable part of each study: the report, the per-session summary and
the manifest that says what binary and what kit revision produced them.

Raw run output — planner DEBUG logs, per-second samples, telemetry scrapes — is
many GB and stays on the VM under `$GVPN_STATE/runs`, where it is deleted when
the disk fills. What lives here is what has to outlive the machine.

One directory per study, named after the file in `studies/` that configured it:

```
results/2026-09-22-pin-vs-auto/
  report.md        the issue-ready document (gvpn-analyze.py --markdown)
  summary.csv      one row per session
  manifest.json    client version, kit revision, profile, run window
  finished.json    end time and exit code
```

`make publish STUDY=<name>` assembles one from the newest run. Review it before
committing — `tools/scan-secrets.sh` runs over it, but a log excerpt pasted into
a report is exactly the case a pattern scan can get wrong in either direction.
