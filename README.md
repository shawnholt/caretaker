# Goliath Caretaker

A lightweight local Windows caretaker for process, listener, service, task, startup, and coverage evidence on Goliath. It is intended to help find resource hogs and unexpected changes without creating a resident agent or broad monitoring stack.

## Current state

The canonical manifest is [`config/caretaker.json`](config/caretaker.json). The approved task-only setup is installed: `GoliathCaretaker-R1` is Ready/Enabled and runs `caretaker.ps1 tick` every 15 minutes. `status`, `doctor`, and setup Plan confirm the exact task; the first scheduled `tick` exited 0 and direct doctor remained `READY`. PerfMon remains off and the named collector is absent; notifications are local-only with delivery disabled. Direct doctor reports `READY`, retention `CURRENT/OK`, and lease start `OFF_BY_POLICY`. The pilot was one on-demand snapshot: 5.25 seconds wall time, 3.14 seconds process CPU on 20 logical processors, projecting to 0.017% whole-machine CPU at a 15-minute cadence. Peak memory and 24-hour overhead are unmeasured; the one-time counter sample is historical only. This is an initial task-only pilot, not sustained acceptance.

Run from this project folder:

```powershell
powershell -NoProfile -File .\scripts\caretaker.ps1 status
powershell -NoProfile -File .\scripts\caretaker.ps1 doctor
powershell -NoProfile -File .\scripts\caretaker.ps1 snapshot
powershell -NoProfile -File .\scripts\caretaker.ps1 tick
powershell -NoProfile -File .\scripts\caretaker.ps1 busy -SampleSeconds 1 -Top 5
powershell -NoProfile -File .\scripts\caretaker.ps1 explain -ProcessId <pid>
powershell -NoProfile -File .\scripts\caretaker.ps1 events -WindowDays 7
powershell -NoProfile -File .\scripts\dashboard.ps1
powershell -NoProfile -File .\scripts\codex-auth-probe.ps1 -CodexPath 'C:\path\to\codex.exe'
powershell -NoProfile -File .\scripts\setup.ps1 -Action Plan
```

- `status` and `doctor` are read-only. They report manifest state, the exact named task, snapshot freshness, coverage, alerts, and lease/retention readiness. They do not inspect unrelated collectors.
- `snapshot` performs one on-demand inventory and writes an atomic snapshot under ignored `evidence/`.
- `busy` samples process CPU for 1–3 seconds and returns bounded JSON with process identity, CPU, memory, and coverage. `explain -ProcessId` returns one live process identity, verified ancestry where available, and bounded endpoint evidence. `events` returns focused System/Application event categories and explicit per-log coverage. These are on-demand; `tick` does not run them.
- `dashboard.ps1` writes `evidence/dashboard.html` from the saved snapshot. It shows snapshot time, freshness, coverage, top working-set processes, and a small TCP listener sample. It does not poll Windows or show live CPU. Regenerate it after a snapshot when needed.
- `codex-auth-probe.ps1` starts one exact native Codex app-server child over stdio, checks `account/read` without refreshing credentials, and verifies that child exits. It prints only auth type and whether OpenAI auth is required. Pass `-CodexPath` to select a native build; without it the script uses the first `codex.exe` on PATH. It creates no thread, turn, listener, or login.
- `tick` reconciles an overdue recorded caretaker lease, performs the snapshot, and applies retention when its daily marker is due. The retention pass removes only valid `changes.jsonl` rows older than 30 days; it preserves malformed rows, outbox state, current snapshots, legacy/protected files, and raw evidence. It reports the storage budget and prevents heavy collection when over budget, but this is not a hard total-directory size cap.
- `setup.ps1 -Action Plan` is read-only. It checks only the exact manifest task and current readiness gates, without querying a PerfMon collector. The installed task followed a passing Plan; run Plan before any future Install.

The manifest currently has `captureLaunchEnabled: false` and no expiry task name, so lease launch remains blocked by policy. Retention and runtime readiness are not established merely by reading the manifest. Check `doctor` and setup Plan for current gates before relying on capture or recurring collection.

The first snapshot establishes a quiet baseline and emits no listener alerts. Later snapshots append compact changes to `evidence/changes.jsonl`. The journal records additions/removals and selected state/action-trigger changes across covered modules; brief process churn is filtered from process change events. The local alert outbox opens and resolves deduplicated items for newly observed TCP listeners after a complete prior baseline and for mismatches in explicitly approved service/task state. UDP endpoints are inventoried and journaled for drift, but do not currently generate listener alerts. A desired listener is approved only when protocol, address, and port match and its configured executable path is nonempty and matches the observed owner. Startup changes are journaled, not currently emitted as alerts. Notifications are not sent externally. Missing or partial coverage is reported rather than treated as healthy.

## Ownership and safety

The caretaker may manage only components created and recorded by this project and verified against their exact manifest identity. Unknown collectors, processes, listeners, services, tasks, and forwarding are evidence for review; they are not automatically stopped or approved.

Existing supervisors retain ownership of their workloads. OpenClaw's native supervisor remains authoritative for its gateway. The Codex bridge remains authoritative for its managed child and stdio lifecycle. This project must not add a duplicate gateway, bridge, app-server supervisor, keepalive, proxy, or watchdog.

The lease CLI uses a unique GUID and native session name, records the launching process identity and bounded output path/size, and arms and verifies a one-shot expiry task before starting a capture. Stop and expiry act only on the recorded exact logman session. `tick` checks overdue recorded leases before the inventory. Report cleanup failure or unknown expiry-task state honestly; do not claim cleanup succeeded without native status evidence.

## Tool hierarchy

Keep it simple: **native API → mature CLI → small borrowed pattern → custom code only for Goliath-specific state**. Do not build wrappers for their own sake.

- **Routine:** use native structured queries, including `Get-NetTCPConnection` and `Get-NetUDPEndpoint`. Use [Sysinternals](https://learn.microsoft.com/en-us/sysinternals/downloads/sysinternals-suite) when a CLI answers a specific question. `Autorunsc` is a candidate for compact startup inventory; `Tcpvcon` is only a fallback when process-attributed endpoints help. [Portmon](https://learn.microsoft.com/en-us/sysinternals/downloads/portmon) covers serial/parallel ports, not network listeners.
- **Reference and manual toolbox:** borrow a narrow read-only drift/query pattern from [BaselineOps](https://github.com/sebastianspicker/baseline-ops), use the [Windows Diagnostics Toolkit](https://github.com/0x0bug/windows-diagnostics-toolkit) for a one-shot report, or [EventLogExpert](https://github.com/microsoft/EventLogExpert) for manual EVTX/live-log review. These are references, not project dependencies or installation plans.
- **Deep escalation:** prefer Microsoft's [ETW MCP early preview](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/etw-mcp-early-preview-july-2026) and [Windows Performance Recorder](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/introduction-to-wpr); treat [nijosmsft/etw-mcp](https://github.com/nijosmsft/etw-mcp) as experimental. Consider [perfmon-mcp](https://github.com/nijosmsft/perfmon-mcp) only if `Import-Counter` is awkward, [mcp-windbg](https://github.com/svnscha/mcp-windbg) for a real dump/hang, and [Hayabusa](https://github.com/Yamato-Security/hayabusa) or [Chainsaw](https://github.com/WithSecureOpenSource/chainsaw) for a focused incident. `sysinternals-mcp` and `winscope-mcp` are only options after a demonstrated need; they are not dependencies.

ProcDump, Handle, ListDLLs, Sigcheck, and ProcMon are on-demand tools. ProcDump's dump count does not bound session duration; ProcMon captures can grow large. Handle can require admin rights; never use its handle-closing option. Any capture must use the lease deadline, output bound, and verified stop path. Do not enable VirusTotal lookups/uploads. Sysmon and dependencies on PsList, PsService, PsKill, PsSuspend, PsExec, Process Explorer, VMMap, or RAMMap are out of Release 1 unless an observed need justifies them. No broad Windows-operations MCP, generic event-log MCP, Atlas, osquery, Fleet, or Velociraptor stack is planned.

## Records and limits

Snapshots retain timestamps, module coverage, and process identity as PID plus creation time, executable path, and parent PID. A lease record stores owner, purpose, target, native session identity, start/expiry, output path/limit, expiry-task identity, and cleanup status. Desired workload approvals and parent-project attribution are still limited; unknown items stay unreviewed, and repeated observation never grants approval.
## Proposed limits and measurements

The manifest is the single source for task identity, cadence, and capture limits. The proposed recurring checker runs every 15 minutes and uses `tick`; PerfMon collection stays off. Evidence policy targets 30 days within 1024 MiB; captures default to 60 seconds with a 300-second maximum. The implemented retention sweep applies only to valid old rows in `changes.jsonl` and reports overall budget use; protected or raw evidence can keep total storage above the target. The one-time counter sample and on-demand snapshot pilot do not prove recurring work, rollover, retention compliance, or 24-hour overhead. The task-only pilot is installed, but 24-hour resource use, rollover, and retention acceptance remain unmeasured; do not treat targets as guarantees until representative measurement verifies them.

## Setup, pause, and uninstall

The user has approved reversible setup of exact caretaker-owned resources. Do not ask again for an eligible action. Use the script's readiness and ownership checks; a collision or failed gate blocks changes.

```powershell
powershell -NoProfile -File .\scripts\setup.ps1 -Action Plan
powershell -NoProfile -File .\scripts\setup.ps1 -Action Install
powershell -NoProfile -File .\scripts\setup.ps1 -Action Pause
powershell -NoProfile -File .\scripts\setup.ps1 -Action Uninstall
```

`Plan` checks the exact manifest task and setup readiness without changing system state; it does not query PerfMon or sample counters. `Install` creates one 15-minute Task Scheduler checker running `caretaker.ps1 tick` with overlap prevention and a bounded execution time. PerfMon remains off; Install creates no collector. It proceeds only when Plan's gates pass and receipt-backed identity checks permit the exact task. It never adopts or overwrites an existing task.

`Pause` disables only the verified caretaker task. `Uninstall` removes only that verified task and preserves evidence files. Both first stop a recorded running caretaker lease and require a verified session stop. Reinstall with `Install` after reviewing Plan if rollback is needed. The lease CLI is:

```powershell
powershell -NoProfile -File .\scripts\lease.ps1 -Action Status
powershell -NoProfile -File .\scripts\lease.ps1 -Action Stop -LeaseId <lease-guid>
```

Capture `Start` remains blocked while the manifest disables it or has no expiry-task identity. Starting a capture requires its exact one-shot expiry task to be armed and verified before the native session starts. Before any future capture, record owner, purpose, target, exact process identity, deadline, and bounded output path; confirm independent expiry before launch. After capture, stop by lease GUID and verify native state is stopped; report missing/changed expiry state or failed cleanup. Routine monitoring never starts a deep capture. `tick` reconciles only the recorded overdue lease before taking a snapshot; an unrelated trace is never stopped.

## Change control and logs

| Class | Scope | Rollback |
| --- | --- | --- |
| REVERSIBLE | Exact caretaker task and registered capture managed through these scripts; covered by the user's standing approval after readiness and ownership checks pass. PerfMon remains off. | Use `Pause` to disable the task or `Uninstall` to remove its definition while preserving evidence. Use lease `Stop` for a recorded capture and verify its result. |
| ADMIN | Any operation that requires elevation. | The agent never elevates. If Windows denies access, stop and log the failure; a user-run command can be provided if needed. |
| OUT OF SCOPE | Other tasks, collectors, services, processes, firewall/network/remote-access/security settings, drivers, OS repair, or broad cleanup. | Requires separate specific approval. Never infer ownership from a name or repeated observation. |

Git is the development history. Runtime `diag_log.txt` records concise failures, warnings, and significant Caretaker actions; it is size bounded with one rotated copy. `change_log.txt` remains for significant caretaker-owned setup or cleanup actions, with outcome and rollback. Routine inspections are not transcribed. Evidence stays under ignored `evidence/`. Do not place credentials, raw process arguments, dumps, or private network details in Git. Never read a log while appending that same read's output to it.

Do not download tools or contact external services by default. A missing or unsupported backup-result source is `UNKNOWN`, not healthy. A listener bind address alone does not prove external reachability.

## Next experience: dashboard, workload memory, and AI

**Dashboard direction.** Make a useful dashboard the near-term primary view. The first slice is an on-demand local HTML view of a timestamped snapshot and coverage, with no resident process. A later on-demand local web UI is the preferred interactive path for refresh, filters, history, and a conversation pane; its service should run only while the UI is open. Keep collection in the existing caretaker commands and expose small versioned JSON results for `busy`, `explain`, and event health. Measure the UI's idle cost and daily usability before choosing a desktop shell. [Tauri](https://v2.tauri.app/start/) is plausible if a packaged shell is justified, but introduces a Rust build path; [Electron](https://www.electronjs.org/docs/latest/tutorial/process-model) brings Chromium/Node processes; [WinUI 3/WebView2](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/webview2) brings a C#/Windows App SDK build and packaging path. Generated HTML alone cannot provide the eventual interaction quality, so it is a prototype, not a permanent UI decision. No UI option has been profiled on Goliath yet.

The 2026-09-23 dashboard mockups guide layout and visual hierarchy only. Their sample values and statuses are not Goliath observations. A UI section must show a timestamp, coverage, and `UNKNOWN` when its real local source is missing; do not manufacture healthy status, backup freshness, updates, process purpose, or chat results from mock content.

**Workload memory choice.** Stay with JSON/files for the next slice. One workstation's review records and current workload list are small; the UI needs lookups by verified executable identity, project, port, class, and review date, plus recent changes. Keep user decisions and approval rules in the canonical manifest, observed first/last-seen data under ignored `evidence/`, and changes in the existing journal. Proposed review classes are `wanted`, `optional`, `temporary`, `review`, and `unknown`. A review record should include purpose, project/application, executable identity, expected ports, launch/startup mechanism, first/last observed, last reviewed, and the user's decision provenance. Only an explicit user decision changes approval; observation and project guesses do not. Implement an atomic, bounded review/observation update and list/query command next. Reassess SQLite when history joins, concurrent writers, or UI filters make file scans or atomic JSON writes materially awkward. Do not create another desired-state authority.

**AI direction (inspection on 2026-09-23).** The dashboard's conversational path should call Codex directly; Caretaker has no `codex-mcp-bridge` dependency. [Official OpenAI documentation](https://learn.chatgpt.com/docs/app-server) identifies app-server as the protocol for custom clients, with stable stdio transport and ChatGPT-managed authentication (`account/read` and `account/login/start`). A UI-owned child can exist only while the dashboard is open, use the user's Codex sign-in, and consume compact Caretaker JSON evidence through narrow read-only tools. A small SDK wrapper may reduce protocol code if it fits the chosen UI backend; verify its auth and lifecycle behavior before choosing it. Keep deterministic health logic local and invoke Codex only for questions needing reasoning. Do not add a separate API-key dependency for ordinary interaction. Normal Codex usage still has account limits; no zero-cost claim is made. A separate Caretaker MCP surface for the normal Codex client may be useful as a companion, but it is not required for the dashboard.

The direct auth probe passed against the installed native CLI 0.153.4: `account/read` returned `authType=chatgpt` and `requiresOpenaiAuth=true`, and the exact child exited. `codex login status` independently reported a ChatGPT sign-in. This proves local auth reuse for a read-only app-server request; it does not yet prove an agent turn, tool callback, dashboard chat, or long-running lifecycle.

The local bridge's documented deployed path is its own ChatGPT-authenticated app-server child over stdio. Its child blocks inherited MCP tools, and its shared Desktop runtime path has ownership/responder gaps. The bridge status document records 0.15.14, but this phase did not prove a fresh external caller turn. These facts reinforce keeping it out of Caretaker's dependency path. The next AI spike is a short direct app-server turn with bounded Caretaker evidence, followed by tool-call and UI lifecycle validation. Do not attach to or change the bridge-owned child.

**Next implementation order.** Add the workload review/observation command, then make the dashboard interactive with the existing bounded JSON commands and one direct Codex app-server conversation slice. Measure UI idle cost and verify one real reasoning turn before expanding the tool surface. The existing 15-minute checker and PerfMon-off setting stay as they are while normal-use overhead evidence accumulates.

## Data and future work

- `config/caretaker.json` is the canonical desired/deployment manifest. Do not copy its identities, thresholds, or counter paths into another authority.
- [`config/GOLIATH.md`](config/GOLIATH.md) keeps user preferences separate from verified machine facts and from the deployment manifest.
- `scripts/caretaker.ps1 tick` is the scheduled task entry point; `status`, `doctor`, `snapshot`, `busy`, `explain`, and `events` are available on demand. `scripts/event-health.ps1` owns the focused event query; `scripts/dashboard.ps1` generates the local HTML view; `scripts/codex-auth-probe.ps1` verifies direct ChatGPT-managed app-server auth without a turn. `scripts/retention.ps1` exposes retention Plan/Apply. `tests/` contains focused fixtures and validation.
- `evidence/` contains local snapshots, change/alert/lease/retention state and the setup receipt; it is excluded from Git. Do not commit raw process arguments, private network details, credentials, dumps, traces, or logs.
- `legacy/` preserves the former one-off event-log scripts and task note. Review scripts before use; `legacy/diag.ps1` runs `sfc /scannow` and may repair system files.
- [`GOLIATH_CARETAKER_HANDOFF.md`](GOLIATH_CARETAKER_HANDOFF.md) preserves the original design handoff, renamed from `Goliath_Caretaker_Plan_and_Codex_Handoff.md` without content edits.

`diag_log.txt` and `change_log.txt` stay at the project root for bounded operational records and are ignored by Git, along with one rotated copy each. Generated XML reports, raw trace/log files, dumps, and the whole `evidence/` tree are also ignored.

## Candidate features

These are candidate next slices for a practical home/dev caretaker, not a release commitment:

- **Resource and drift view:** extend on-demand `busy` from process CPU and memory to useful disk/network pressure where cheap, and add last-day/week comparisons for listeners, startup/persistence, tasks, services, and high-signal events. Extend `explain` beyond PID to executable name and port, with verified project, launch, and service/task attribution. Current periodic snapshots do not measure resource intervals or read event logs; event health runs only on demand. Keep temporary-monitor expiry and verified cleanup as a hard requirement. Add low-noise deduplicated alerts and a small daily digest as useful; deep ETW tracing and any outside heartbeat can wait.
- **Lightweight workload memory:** remember only useful facts such as owner, purpose, project, installer/launch source, expected ports, review date, and a simple class: wanted, optional, temporary, review, or unknown. Register apps when launched or when a decision is made; prompt occasionally about stale items (for example, a Node server seen for 12 days on port 3000 with no recorded purpose). Cover forgotten Node/Python/Codex/MCP/WSL experiments and temporary monitors without creating a manual CMDB. Repeated observation never approves a workload or authorizes stopping it.
- **Known Node project updates:** check dependency status only in identified Node project roots, report outdated dependencies without installing them, and show the project root used. Avoid broad repository scans. [npm outdated](https://docs.npmjs.com/cli/v11/commands/npm-outdated)
- **Backup freshness:** report per-job Duplicati/QNAP last success, failure, and overdue state only from a supported local result source. Keep each job `UNKNOWN` until the source and result are verified. [Duplicati reporting and monitoring](https://docs.duplicati.com/monitoring-and-notifications/sending-reports-via-email)
- **Software and security review:** add an on-demand report-only WinGet update view; installing an update remains a separate user action. Later, show only relevant Defender state and vendor/KEV advisories matched to verified installed products. [WinGet upgrade command](https://learn.microsoft.com/en-us/windows/package-manager/winget/upgrade)
