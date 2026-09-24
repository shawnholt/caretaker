# AGENTS.md

## Purpose and scope

This project develops a local Windows caretaker for Goliath. Work only within this project folder unless the user explicitly expands scope. Do not inspect unrelated repositories, disks, private locations, or network services.

Release 1 project-file work is authorized in this checkout: read and edit project documentation, `config/`, `scripts/`, `tests/`, and local fixtures as needed for the approved feature scope. The user has also approved reversible setup and operation of exact caretaker-owned resources when the project scripts' ownership and readiness checks pass. This standing approval does not extend to unrelated workloads or other Windows/application changes.

## Windows safety

- Use targeted, non-admin, read-only diagnostics by default.
- Never run elevated commands. If an explicitly approved step requires admin, provide one self-contained script for the user; do not execute it.
- The standing approval covers only the exact caretaker checker task and reversible lifecycle actions, plus future bounded captures when their lease preflight passes. PerfMon remains off in the current task-only setup. Do not ask again for each eligible action in the approved scope. Use the project setup/lease scripts and their Plan/preflight gates; collisions, mismatched identity, or failed readiness checks block the action.
- Do not elevate or self-elevate. If an approved caretaker action requires administrator rights, stop at the permission error, log it, and provide a self-contained command for the user to run if needed.
- Get separate approval before changing any other service, scheduled task, PerfMon collector, registry, power, firewall, networking, remote access, security policy, installed software, driver, or OS state; before stopping any unrelated process/collector; or before cleanup outside caretaker-owned paths.
- Never start or stop an unknown/pre-existing collector, process, service, task, or listener. Only manage exact caretaker-owned identities recorded in the canonical manifest and proven by local evidence.
- Do not run `legacy/` scripts without reviewing their behavior. In particular, `legacy/diag.ps1` runs `sfc /scannow` and may repair system files.
- Do not download tools or contact external services by default.

## Evidence and state

Separate observed facts, desired/approved state, decisions, active leases, and coverage. Repeated observation does not approve a workload. Treat unavailable evidence as `UNKNOWN`, not success. Validate executable identity, process creation time, and ancestry before attribution or action; a PID or process name alone is insufficient. A wildcard bind is not proof of internet exposure.

OpenClaw's native supervisor owns its gateway. The Codex bridge owns its managed-child/stdio lifecycle. Do not add duplicate supervisors, gateways, keepalives, proxies, or watchdogs.
The read-only direct Codex auth probe may start one short-lived app-server child that it owns, with verified PID, creation time, executable path, and exit. It must not attach to or alter the bridge-owned child, copy credentials, open a listener, or leave a resident supervisor. Chat and the auth probe currently require a native `codex.exe` (`CARETAKER_CODEX_EXE` or PATH); the npm PATH `codex` wrapper alone is insufficient until the deferred wrapper-resolution fix in README is implemented.
The owner also requested an on-demand chat window. `scripts/chat-server.js` may bind one ephemeral `127.0.0.1` port while its UI is in use and start its own native Codex app-server stdio child. It must reuse Codex's existing ChatGPT sign-in without copying credentials, disable inherited integrations before turns, and close its exact child and listener on Stop/page close/idle expiry. The model picker uses the app-server's available-model list. Chat may call only the bounded read-only Caretaker actions declared in that server (resource sample, process details, event health, inventory, and status); inventory may refresh ignored project evidence. It cannot accept arbitrary commands or make Windows configuration changes. This does not approve a firewall change, persistent service, background supervisor, or any other listener.

Prefer native structured Windows APIs for routine inventory; use Sysinternals command-line tools when they answer a focused question with less code. Add custom code only for Goliath-specific state. Keep Autorunsc optional until it materially improves compact startup coverage. Use ProcDump, Handle, ListDLLs, Sigcheck, and ProcMon on demand only; collector sessions require the lease's owner, deadline, output bound, and verified stop. Never use Handle's close option or enable VirusTotal uploads. Do not add Sysmon or dependencies on PsList, PsService, PsKill, PsSuspend, PsExec, Process Explorer, VMMap, or RAMMap without a demonstrated need.

Temporary diagnostic capture is currently disabled by manifest policy (`leaseStart: OFF_BY_POLICY`). Before any future capture, confirm owner, purpose, target, exact process identity, evidence path and output limit, deadline, and independent one-shot expiry; verify the expiry task before starting only the recorded native session. After capture, stop that exact session, verify native stopped state, and remove only its exact expiry task. Preserve state and report failure if cleanup is unproved. Routine monitoring does not start deep captures. Never globally cancel an unrelated trace.

## Logging

Git is the development history. Do not transcript inspection or development commands into `diag_log.txt` or `change_log.txt`. Runtime logs should record failures, warnings, significant caretaker actions, and concise operational outcomes. Bound retained runtime log size; never include raw process arguments or private evidence. Never read a log while appending that same read's output to it. Keep raw/private evidence under ignored `evidence/`; do not commit logs, XML reports, traces, dumps, credentials, raw process arguments, or private network details.

For actual caretaker-owned setup, lease, or cleanup actions, retain a concise action/outcome/rollback record. No development-command audit log is required.

## Validation and deployment

Use the self-logging setup script's read-only Plan action before setup. Its Install, Pause, and Uninstall actions may manage only receipt-verified caretaker resources covered by the user's standing approval, and must preserve the documented rollback and evidence. Do not enable notification delivery or create other persistent components outside that exact scope. Report project build/fixture checks separately from setup, activation, and real-caller acceptance. Separate short pilot measurements from sustained targets; do not claim 24-hour resource or retention targets achieved without representative evidence.

## Change control

| Class | Examples | Authorization and rollback |
| --- | --- | --- |
| REVERSIBLE | Exact caretaker task setup, pause, uninstall, and a bounded caretaker-owned capture; PerfMon remains off | Standing user approval applies after script ownership/readiness checks pass. Log command/output and native changes. Use the setup or lease script's exact pause/uninstall/stop action; preserve evidence and report cleanup failures. |
| ADMIN | Any command requiring elevation | The agent never elevates. Stop on access denied and report the exact blocker; provide a self-contained user-run command only when the requested caretaker action is otherwise approved. |
| OUT OF SCOPE | Unrelated workloads, services, tasks, collectors, firewall, remote access, security policy, drivers, OS repair, or broad cleanup | Obtain separate specific approval before acting. Do not infer authority from repeated observation or caretaker approval. |

The canonical manifest is `config/caretaker.json`; do not create a second desired-state or deployment checklist. `config/GOLIATH.md` stores user-provided preferences separately from verified machine facts; it is not another desired-state source. The caretaker CLI includes `status|doctor|snapshot|tick|busy|explain|events|review` and on-demand analysis actions as implemented; setup actions are `scripts/setup.ps1 -Action Plan|Install|Pause|Uninstall`; lease actions are `scripts/lease.ps1 -Action Status|Start|Stop|Expiry`; retention actions are `scripts/retention.ps1 -Action Plan|Apply`. Keep docs aligned with actual runtime behavior and label planned behavior clearly.
