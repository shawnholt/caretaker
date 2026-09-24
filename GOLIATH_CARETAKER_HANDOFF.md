# Goliath Caretaker: plan and implementation handoff

Date: September 23, 2026
Status: design only. This document does not establish that any collector, scheduled task, alert channel, or cleanup is installed or operating on Goliath.

## 1. Goal

Give Shawn a lightweight, persistent operational memory for Windows Goliath. Identify what is running, why it exists, what starts it, what ports it uses, what resources it consumes, and whether it remains wanted. Never leave project-owned diagnostic collection running indefinitely. Detect useful changes without an always-running LLM. Make “what is slowing things down?” an evidence-backed query rather than a new investigation from scratch.

Priorities, in order:
1. Own and expire temporary diagnostic collection; discover forgotten external collectors without indiscriminately stopping them.
2. Identify resource-heavy applications and forgotten test servers, including their parent application/project and startup mechanism.
3. Track TCP listeners, UDP endpoints, expected bindings, and relevant forwarding/exposure changes.
4. Track startup, enabled/disabled state, services, scheduled tasks, software/driver drift, backup freshness, and essential security state.
5. Proactively deliver a small number of actionable alerts.
6. Add deep performance tracing and narrowly relevant security advisories only after the basic caretaker works.

This is a caretaker, not a performance optimizer, antivirus replacement, application-usage surveillance platform, or enterprise observability stack.

## 2. Context to preserve and verify locally

Goliath is Shawn's Windows development workstation. Prior context reports Windows 11, WSL/OpenClaw, Codex/Desktop/My Agent components, Node/Python experiments, Tailscale, and Duplicati backups to QNAP. Treat installed versions, current processes, enabled jobs, backup coverage, and network exposure as unknown until read locally.

Existing project root reported: `C:\Users\pub\Python`.
Existing bridge project reported: `C:\Users\pub\Python\codex-mcp-bridge`.
Prior one-off diagnostics may exist outside this repository. Discover targeted existing files before creating overlapping collection.

The bridge's fetched operations guide already defines lifecycle/status/startup commands and process/profile ownership rules. Reuse its supported status interfaces; do not introduce another bridge or app-server supervisor. Do not change its authentication, profile ownership, or production runtime as part of this project.

OpenClaw's existing native supervisor is to remain authoritative. Do not add a duplicate gateway, keepalive, proxy, or watchdog. Discover current WSL distributions before using any remembered name/path. Do not launch a stopped distribution or Docker simply to inventory it.

Past storage-reset incidents and unexplained diagnostic/search load deserve explicit rules. A remembered `rg.exe` incident does not prove every instance belongs to ChatGPT; identify the executable, process creation time, and validated ancestry.

## 3. Architecture and deliberate scope limits

Use existing Windows mechanisms:
- One small native PerfMon Data Collector Set for bounded rolling performance history.
- One recurring Task Scheduler entry for a short deterministic check, with slower checks staggered internally.
- Temporary expiry tasks only when needed to enforce an owned diagnostic session's deadline independently of the initiating shell/agent.
- Local JSON state/deltas, compact summaries, and an append-only decision/action journal. Single writer, atomic updates, bounded retention. No database server.
- One reusable Codex skill that reads those artifacts and invokes reviewed tools on demand.
- One outgoing notification adapter when configured. No new inbound listening port or web dashboard.

No always-thinking agent, local inference server, SIEM, Grafana stack, custom MCP server, global package scanning, full-drive indexing, or second service supervisor in v1. Do not install a toolbox of overlapping agents.

WDT remains an optional pinned, unmodified diagnostic report generator, not a core scheduled dependency. Native targeted queries and Autorunsc cover the first release's operational inventory. Add WDT only if a specific missing collector justifies its measured cost.

Official ETW MCP, TSS, ProcDump, WinDbg, ProcMon, and sensor tools are optional incident tools. Install or activate only when a concrete investigation needs them and required permissions are approved.

## 4. The central data model: observed state is not approved state

Maintain separate records for:
- Observed facts: process identities, current ports, resource deltas, inventory versions, startup settings, last observations, and evidence timestamps.
- Desired state: approved permanent/optional/temporary workloads, expected listeners, required startup behavior, protection flags, review dates, and approved stop/expiry policies.
- Decisions: what Shawn approved, stopped, postponed, or exempted, with reason and evidence.
- Active diagnostic leases: owner, purpose, target, start/expiry, output location, limits, and verified cleanup status.
- Coverage: each check's enabled state, last attempt, last success, freshness, failure/permission reason, and next due time.

Never automatically bless an existing or newly discovered entry merely because it was observed repeatedly. Never replace an approved baseline with the latest observed state. Quiet repeats should be deduplicated without becoming approved.

Use human application/project identities, not broad allowances for `node.exe`, `python.exe`, `rg.exe`, or `svchost.exe`. A running process instance must include PID and creation time; validate its executable and ancestry before attribution or action. Parent PID alone is not sufficient because IDs can be reused.

An item can be protected/required, approved optional, explicitly temporary, or unreviewed. Runtime status and permission/coverage status are separate attributes.

## 5. Temporary collectors: expiry is mandatory

A diagnostic operation is incomplete until it proves that collection stopped or explicitly reports cleanup failure.

Before starting a managed trace, profiler, process watcher, packet capture, or long-running sampling job:
- Register an exact owner and purpose, native session/process identity, target, output path, deadline, resource/output limits, and approved stop method.
- Arm a native duration limit when the tool supports one. Arrange independent cleanup before launch where needed; refuse the launch if cleanup cannot be armed safely.
- Use a unique native session identifier where supported. Verify installed tool capabilities rather than assuming documentation for a newer version applies locally.
- Detect existing/conflicting sessions. Do not issue a global cancel that could stop somebody else's recording.

Starting policy: 60-second ordinary deep capture; five-minute ceiling without a specific extension. Longer waits for rare events, boot tracing, or process dumps are special, explicitly bounded sessions, not default behavior.

Cleanup must work after the initiating Codex task, shell, or terminal exits. A scheduled task timeout alone is not proof that an ETW session or descendant process stopped. Verify the native recording state, exact owned processes, output growth, and any persistent tracing flags changed by the session. Preserve original settings and restore only owned changes.

The recurring checker reconciles overdue leases and orphaned expiry tasks, including after reboot/resume. Retries are bounded. Report STOP_FAILED if cleanup cannot be proved; do not silently claim success.

Discover pre-existing WPR/ETW/PerfMon, ProcMon/ProcDump, pktmon/netsh traces, custom polling scripts, and other resource-heavy diagnostics. Classify them as known Windows/security infrastructure, approved permanent recording, owned temporary recording, or unknown. Unknown collectors are reported with evidence and a proposed stop action; they are not automatically killed. Windows' normal event and trace infrastructure is protected.

Provide a safe “stop temporary diagnostics” operation that affects only explicitly owned sessions. Stopping/removing the caretaker itself must first stop its owned temporary captures and then remove its own schedules and recorder, without touching unrelated monitoring.

## 6. Workloads and experiments

Automatically discover long-lived processes and listeners. Associate them with a service, scheduled task, application, project, container, or existing supervisor wherever evidence permits. Record first/last observation, executable identity/version, redacted arguments, relevant ancestry, startup mechanism, resources, ports, and expected lifecycle.

For new agent-launched background experiments, require automatic registration before they survive the turn. Record purpose/project, deadline or review date, port expectations, and whether automatic termination at expiry is explicitly authorized. A reusable launch helper may use Windows Job Objects where appropriate to group owned children, but must not replace production service supervisors.

Synchronous short commands that exit within their bounded call do not need individual human-facing registry entries. Preserve useful launch metadata without creating a new bookkeeping burden.

For unmanaged existing jobs, prompt after a configurable duration/review interval rather than kill. Start with a daily batch of at most three material review items. Examples of decisions: keep permanently; keep through a date; stop this exact test process; disable this exact startup entry. Record decisions so they survive new chats.

Low CPU, no active TCP connection in a snapshot, or no recent foreground observation does not prove disuse. Distinguish last-seen-running, observed connections, and last human confirmation. Do not label a program “unused for 30 days” without adequate usage evidence and coverage.

If a stopped process returns, identify the actual startup/supervisor source rather than repeatedly killing it. Service and application changes need dependency, remote-access, and unsaved-work checks.

## 7. Ports and exposure

Track TCP listening sockets and UDP bound endpoints for both IPv4 and IPv6. Store protocol, bind address, port, owning process instance, application/project, first seen, last seen, expected binding, and approval status. Do not alert on ordinary outbound ephemeral connections as if they were new servers.

Separate:
- Loopback-only binding.
- A LAN interface or wildcard binding.
- Known overlay/tunnel/forwarding exposure.
- Externally reachable exposure confirmed by a separate authorized check.

A wildcard listener is not proof of internet reachability. A loopback listener is not proof of isolation if a reverse proxy or tunnel forwards to it. Check relevant local firewall changes and already-running Tailscale/WSL/Docker forwarding when supported; mark unknown exposure explicitly. No routine packet capture or network scan.

Discover existing bridge, SSH, remote-access, and OpenClaw listeners before classifying them. Never automatically close ports or firewall rules needed for recovery or remote access.

First alert priorities: a new unreviewed persistent listener, changed loopback-to-wildcard binding, unexpected forwarding, a known required port disappearing, or repeated binding failures/port conflicts.

## 8. Drift and startup checks

Use native Windows service/task/software inventory plus Microsoft Autorunsc rather than reimplementing every autostart registry location.

Hourly lightweight changes: service startup modes and state, scheduled task enabled state/action/trigger and recent results, relevant startup settings, and firewall/forwarding changes.

Daily slower changes: installed applications including relevant per-user/machine installations, driver versions, OS updates/reboot state, Defender protection/detection status, backup freshness, and current known workload declarations.

Weekly or targeted audit: broader Autorunsc report, newly changed binary signature checks, unresolved optional background apps, and approved exceptions due for review. Keep Microsoft entries in the underlying baseline even if the human report emphasizes third-party changes. VirusTotal upload is off by default.

“Running,” “installed,” and “needed” are distinct. A manual or trigger-start service that is stopped is not a failure. Expected state must account for logon, uptime, user session, sleep, startup grace periods, and an application's own supervisor.

Do not run MSI inventory queries that trigger installation consistency checks, recursive executable hashing, repeated full SMART tests, all-repository package audits, or broad filesystem searches on a schedule.

## 9. Backup checks

Start with Shawn's existing Duplicati configuration and actual jobs; do not replace or duplicate backup software. Prefer existing supported result/status reporting or a stable documented completion interface. Avoid reverse-engineering internal databases or adding a local HTTP server merely to receive backup results.

Per job, record schedule, protected source set, destination identity, last attempt, last completed result, last confirmed successful backup, warnings/failures, next expected run, grace period, and last restore test if known.

A running Duplicati process, successful scheduler launch, reachable QNAP, or recent folder timestamp is not evidence of a successful backup. An unavailable result source is UNKNOWN, not green. Do not invent job success, coverage, or restorable status.

Use elapsed time since successful completion against the actual schedule. For a daily job, 48 hours may be a starting warning threshold, not a hard-coded rule for every job. Report wall-clock backup age honestly even if the PC was asleep; explain missed opportunities/grace rather than hiding age.

Distinguish failed, overdue, still running unusually long, successful with warnings, and backup health unknown. Later add a bounded restore-validation workflow; success reports alone do not prove all important data is recoverable.

## 10. Low-cost alerts and AI

Local rules produce structured alerts and readable template messages without LLM calls. Store a durable outbox with deduplication, delivery attempts, last delivery error, acknowledgment, suppression expiry, severity, and resolution.

Urgent: confirmed active Defender problem, an owned heavy trace that failed to stop, a high-confidence dangerous exposure change, serious sustained storage/hardware trouble, or an essential workload/backup failure.

Routine digest only when changed: unreviewed background apps, stale experiments, startup additions, repeated lesser errors, and overdue reviews. Batch to one digest per day with a small action count. No routine “everything normal” messages. Use cooldowns and sustained conditions rather than one-sample CPU spikes.

Use one existing working outgoing channel after discovery. Do not deploy or repair OpenClaw solely to send notifications; do not depend on it for the local caretaker. A phone push or chat channel must pass a real end-to-end delivery test before “proactive alerts enabled” is reported. Until then, explicitly show local-only/pending delivery. Remote messages carry summaries, not raw paths, full arguments, dumps, or credentials.

Codex Desktop is the primary interactive investigator. A shared skill must be discoverable from relevant projects without duplicating the full runbook everywhere. Read a small current summary, policy decisions, and evidence handles first. Fetch bounded supporting evidence only as needed. Separate observations, correlation, hypothesis, and confirmed cause.

V1 unattended LLM use: zero. Optional later triage: one bounded pass for a novel unresolved incident, at most one automatic retry, configurable total tokens/calls, and one active analysis at a time. Exhausted quota or unavailable model leaves a saved incident and a deterministic alert; never an autonomous retry loop. Do not assume API usage is included in a subscription or silently change authentication/billing.

## 11. Relevant security advisories, later

Use CISA KEV data and relevant vendor advisories, including Microsoft, matched to verified installed product/version information. Cache once daily and process only changes. The goal is not to announce every headline or every CVSS-critical issue.

Every alert must say which installed component may be affected, what version/exposure was observed, the advisory/evidence, uncertainty, and the specific update or mitigation to consider. Verify affected/fixed ranges from vendor guidance. KEV is a prioritization source, not a complete vulnerability scanner and not a complete version-matching engine.

A new worm advisory is not evidence that Goliath is infected. Preserve that distinction. Leave malware protection to Defender; do not automatically disable protections or add exclusions. Scanning every npm/Python environment or crawling the whole disk is out of v1 scope.

## 12. Resource budget and safety

Proposed starting settings, to validate on Goliath rather than advertise as achieved:
- Native PerfMon: narrow CPU/memory/storage and a small set of process counters, approximately 15-second samples. Resolve available/localized counters and validate sample status. Include process identity linkage; do not interpret cumulative lifetime CPU as current load.
- Recorder capacity: 512 MiB. Report actual oldest/latest usable sample; a size cap does not guarantee 72 hours. Preserve incident windows safely without copying a live file as if it were a consistent export.
- Recurring check: every five minutes, skip overlap, short per-module timeouts, short overall deadline. Heavy daily/weekly work staggered and deferred during pressure. Lease cleanup must not be blocked by slow inventory or network calls.
- Target total routine overhead below 0.5% of whole-machine CPU averaged over a representative window. Measure aggregate CPU, memory peak, I/O, and log growth including child tools and shared collector effects; this is a target, not a current result.
- No new listening port; no resident custom LLM or service. Processes used for scheduled checks exit after work.
- Bounded histories and quotas, e.g. up to 30 days of compact changes within a 1 GiB normal-data budget. Separate explicit trace/dump budget. If retained unresolved evidence prevents quota compliance, stop new heavy collection and alert rather than delete protected evidence silently.
- No waking Goliath, stopped WSL distributions, Docker, or sleeping disks merely to probe them unless explicitly approved.

On pressure/overrun, stop or defer nonessential owned collection first and report degraded monitoring. Do not disable essential security or someone else's tracing. Adaptive backoff must never turn missing data into “healthy.”

Read-only discovery by default. Narrow reviewed elevated helpers only when required; keep privileged code and action configuration in ACL-protected deployment paths, not an arbitrarily editable working repository. An LLM must not execute arbitrary privileged commands from an alert/log field. Treat logs and process arguments as untrusted data. Redact secrets before saving routine summaries or sending them to AI.

Automatic authority: stop owned expired diagnostic sessions, end explicitly registered auto-expiring disposable jobs, prune only owned unprotected files under retention, and maintain only the caretaker's approved registration. Everything else is a proposal unless a specific standing policy authorizes it. Restore/disable/start/kill/reboot/driver/firewall/Defender/backup changes require approval and verification.

## 13. What the conversational experience should answer

- “What is slowing things down?” Attribute recent measured load to application/project, not just a process filename. Check storage latency, commit/paging, sustained CPU, and relevant events, not only CPU ranking.
- “Why is rg.exe busy?” Resolve exact path/creation time/ancestry and search context where visible; do not assume all instances have the same owner.
- “Can I free memory?” Identify optional workloads and actual pressure. Avoid automatic working-set/standby-cache purges or ending protected jobs merely to increase the free-memory number.
- “Do I need these background apps?” Present a few evidence-ranked review candidates with purpose, persistence, resource cost, dependencies, and reversible next action.
- “What ports are open?” Show listener/endpoints, owning application, expected bindings, and known versus unknown exposure.
- “Why did it not start?” Compare expected startup behavior with native service/task/supervisor status, last attempt, result, relevant logs, and port conflicts.
- “Stop my temporary diagnostics.” Stop only owned bounded sessions and prove the result.
- “Keep that, it runs my backup.” Persist the decision in the correct application/workload record.

## 14. Visibility limits that must remain explicit

Five-minute inventories and 15-second counters can miss short-lived processes and brief stalls. V1 is not a complete forensic process history. Agent registration improves attribution for managed jobs; add narrowly scoped launch-event capture later only if observed gaps justify its footprint.

Application use and need cannot be reliably inferred from idle CPU or sampled connections. Required/optional intent comes from recorded decisions and workload configuration.

Coverage gaps, access denied, stale data, unavailable backup results, and uninspected WSL/containers remain UNKNOWN or DEGRADED, never OK.

A local checker cannot send a message while Windows is down. Initial recovery reports missed checks on the next start. A later independent heartbeat observer on an already-running external system is required to alert on missing check-ins. Missing heartbeat means unavailable/unknown, not proven boot hardware failure; accommodate intentional shutdown and network loss.

## 15. Implementation sequence

### Release 1: stop starting from scratch

Implement the smallest end-to-end path that produces a useful status on Goliath:
- Targeted read-only discovery of existing diagnostics, processes/listeners, startups/services/tasks, backup reporting, and existing agents. Reuse before adding.
- Desired/observed records, compact state, and one command/skill entry to view status.
- Owned collector registration, expiry, independent cleanup, verification, and pause/uninstall behavior.
- Minimal PerfMon history plus periodic process/port/drift checks and caretaker self-health.
- Duplicati freshness adapter if a supported local result source is available; otherwise explicit UNKNOWN with the smallest missing integration documented.
- Deterministic alert outbox, local visibility, and one tested outgoing channel if already usable. Do not add a new communications platform as a dependency.
- No automatic cleanup of unreviewed existing applications.

Release 1 is useful even without automatic LLM calls, elaborate dashboards, vulnerability matching, or complete application-usage inference.

### Release 2: controlled experiment cleanup and better explanations

Add launch registration for background agent jobs, safe explicit expiry, persistent keep/review/stop decisions, relevant WSL/container/supervisor adapters, and targeted ETW/TSS escalation with the same cleanup contract. Tune thresholds from actual incidents and measured overhead.

### Release 3: narrowly relevant advisories and independent availability

Add curated installed-product advisory matching, backup restore evidence, and an external missing-heartbeat observer using existing infrastructure. Add bounded unattended LLM triage only if deterministic messages prove insufficient.

## 16. Acceptance criteria

Use unit/fixture tests and disposable narrowly scoped local tests. No uncontrolled stress tests, network exposure, or production reboots for validation.

- A managed short trace stops after its deadline even if the initiating shell/agent exits. Native status proves no owned session remains.
- A different pre-existing diagnostic session remains untouched.
- A disposable managed test server is recorded with its port and is removed at expiry only when termination was authorized; an unrelated same-name executable survives.
- PID reuse and invalid ancestry fixtures do not cause misattribution or a wrong kill.
- New listener, changed bind, disabled required startup, and unexpected task action changes appear in the review queue. Routine outbound ephemeral ports do not become listener alerts.
- An overdue successful-backup timestamp produces the correct alert; missing or warning-only result evidence does not become green.
- Repeated identical facts produce no repeated notification/model calls. Silence on a healthy unchanged run costs zero LLM tokens.
- Task overlap, reboot/resume, access-denied reads, unavailable WSL, network timeouts, log rollover, failed alert delivery, and stale snapshots have truthful states and bounded retries.
- Failed/adversarial raw log strings cannot become executable privileged instructions.
- Installation is idempotent and does not create duplicate tasks/recorders. Pausing is distinguishable from failure. Uninstall stops/removes only owned components and preserves user-selected evidence.
- Resource usage is actually measured. Any unmeasured 24-hour target is labeled pending, not passed by extrapolating a brief test.

## 17. Canonical documentation and ownership

Use one small project, reusing an existing suitable operations repo if discovered, otherwise propose `goliath-health` under the established project root. Do not bury it inside codex-mcp-bridge.

Keep editable code/policy/docs in the project. Keep protected deployed helpers and private runtime data under an appropriate ProgramData location with explicit ACLs. Raw inventories, process arguments, private network data, tokens, and traces do not belong in GitHub. Back up approved policy, decisions, and small incident summaries through the existing backup system; rotating raw telemetry need not be archived by default.

Minimum documentation:
- README: purpose, architecture, one-command status, pause/resume, uninstall, and actual deployed status.
- Policy/manifest: every owned task/collector, frequency, limits, expected workloads, coverage, expiry behavior, and permissions. Generate coverage/status from this rather than maintain duplicate checklists.
- Operations runbook: how checks/alerts fail, how to stop recording, how to recover, and rollback boundaries.
- One Codex skill plus a minimal discovery pointer available from relevant projects.
- Append-only decision/action journal and acceptance evidence.

Do not enforce an arbitrary six-file limit if separation makes safety and tests clearer. Keep the runtime dependencies and responsibilities small instead.

## 18. Focused Codex implementation directive

Read this brief and treat Release 1 as the goal, not the entire roadmap. Start with targeted local inspection of existing Goliath diagnostics, scheduled tasks, process listeners, and Duplicati reporting. Inspect the relevant existing bridge/OpenClaw operations interfaces before integrating; do not scan repositories or disks indiscriminately.

Produce a working read-only status path and automated tests, then implement registered bounded diagnostics with independent cleanup. Preserve source attribution, coverage uncertainty, and protected workloads. Make focused changes using existing patterns; do not write a new agent platform, infer that old versions/ports are current, or fix unrelated runtime problems.

Build and test in the project without enabling new persistent monitoring until the actual install manifest and permissions are approved, unless the user has explicitly authorized that installation. Never stop existing apps/services/traces, alter remote access, repair disks, change Defender exclusions, or reboot without specific authorization. Disposable tests must be loopback-only, explicitly owned, and cleaned up.

At each completed slice, record implemented versus planned capability and concrete test evidence. If blocked, state the smallest blocker and next cheapest action; do not turn one missing adapter into an open-ended redesign. Final handoff must include exact running/installed components, measured overhead, gaps, tests, rollback/uninstall instructions, and the command that answers “what is slowing Goliath down?”

## 19. Primary references reviewed

These sources establish tool capabilities, not that Goliath is configured or healthy. Product/version requirements must be checked on the installed host.

- Microsoft logman counter capture: circular format, interval, duration and output-size controls. `https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/logman-create-counter`
- Microsoft WPR options: native start/status/stop and instance selection. `https://learn.microsoft.com/en-us/windows-hardware/test/wpt/wpr-command-line-options`
- Microsoft Task Scheduler settings: execution deadlines, overlap, priority and missed-run settings. `https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtasksettingsset?view=windowsserver2025-ps`
- Microsoft Win32_Process: creation time and parent-PID reuse limitations. `https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-process`
- Microsoft TCP and UDP inventory. `https://learn.microsoft.com/en-us/powershell/module/nettcpip/get-nettcpconnection?view=windowsserver2025-ps` and `https://learn.microsoft.com/en-us/powershell/module/nettcpip/get-netudpendpoint?view=windowsserver2025-ps`
- Microsoft Autoruns/Autorunsc: autostart categories, CSV export, signature and VirusTotal options. `https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns`
- Microsoft Job Objects. `https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects`
- Duplicati's supported reporting and monitoring guidance. `https://docs.duplicati.com/monitoring-and-notifications/sending-reports-via-email`
- CISA's official KEV data repository and formats. `https://github.com/cisagov/kev-data`
- OpenAI skill documentation and progressive disclosure. `https://developers.openai.com/codex/skills/`
- Existing bridge operations guide, read as repository documentation rather than live runtime evidence. `https://github.com/shawnholt/codex-mcp-bridge/blob/main/docs/OPERATIONS.md`
- Shawn's supplied “Windows Goliath: AI-Assisted Windows 11 Diagnostics :  Research Verdict,” which supports deterministic collection, persistent baselines, compact evidence, reusable skills and separately authorized remediation.
