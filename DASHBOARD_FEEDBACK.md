# Dashboard feedback and backlog

Status: **product feedback only; no implementation approved by this note.** Source: the owner's eight browser comments on the generated dashboard. The selected page text and screenshots identify what was being reviewed; their process names, addresses, counts, times, and statuses are not requirements or independent machine evidence. The earlier mockups remain visual inspiration, not literal content.

## Overall direction

Make the dashboard understandable at a glance: show useful conclusions and the evidence behind them, use ordinary local time, explain unfamiliar terms in place, and let a user move from a summary into the relevant records. Do not present collection success as machine health or a listener count as a problem by itself. Resource views should eventually describe activity over a stated period, with honest coverage and sampling limits.

## Comment record

| # | Area | Owner feedback | Product interpretation to retain |
| --- | --- | --- | --- |
| 1 | Captured time | “local timezone. make it look normal” | Show a readable local date and 12-hour time with the correct EDT/EST zone for that date. Keep the underlying UTC timestamp in saved evidence. |
| 2 | Freshness | “clean” | Shorten the large freshness sentence into a scannable status and age; put cadence and calculation details in help text. Fix the displayed broken dash/encoding. State when freshness was calculated because the HTML is static. |
| 3 | Listener summary | “not really relevant. put in listener area” | Move the listener count out of the top summary cards and into the listener section. Give the top row to more useful, explainable information. |
| 4 | `6 / 6 OK` | “what is this?” | Explain that this counts inventory modules whose collection reported `OK`. It does **not** mean six health checks passed or that Goliath is healthy. Prefer plain language over the bare fraction. |
| 5 | Help | “everything with tool tip ? to understand it” | Add concise, accessible `?` help for metrics, statuses, counts, and unfamiliar terms. Help must work by click/focus as well as pointer hover. Define source, period, meaning, and important limits. |
| 6 | Coverage modules | “needs to click into module. all need tool tip with what it is” | Make each module a path to its underlying records or a clear unavailable state. Explain what each module inventories and what `OK`, `DEGRADED`, and `UNKNOWN` say about collection. |
| 7 | Listeners | “make it clear if this is normal, or if there is an issue. should have a rule” | Add an explicit, evidence-backed review rule and explain the result beside listener records. A count or bind address alone cannot establish danger or external exposure. |
| 8 | Resource hogs | “is this just memory? then say so… single view with sub menu (tabs) show hogs… mem, cpu etc. should be cumulative in snapshot period not a single point in time” | Label the existing working-set table as memory at one capture. Plan one resource-hogs view with metric tabs. Period-based CPU and memory claims require real historical samples, a named window, and coverage; do not relabel a point-in-time value as cumulative. |

## Rules and unresolved design work

- **Listener assessment:** Start from the existing approved-listener identity rules and observed changes. A future UI may distinguish an explicitly expected listener, a new/mismatched listener needing review, and insufficient evidence. It should show the reason and link to the exact observation. Decide the display rule against the canonical manifest and alert logic before presenting a “normal” or “issue” verdict. Repeated observation does not approve a listener; a wildcard bind does not prove internet reachability. No new rule or threshold is adopted here.
- **Resource history:** The current dashboard reads one saved snapshot and can show working set at capture time. The on-demand `busy` command takes a short CPU sample; neither source establishes cumulative CPU use or memory use over a 15-minute period. Define the window and measures before adding tabs: for example, CPU time or average sampled CPU; for memory, average or peak sampled working set rather than a sum of memory values. Account for missed intervals and process identity across PID reuse. Disk/network tabs require their own source and coverage. No new collector or history storage is authorized by this feedback note.
- **Drilldown and help:** Decide which module records are safe to display locally and how to label unavailable or partial data. A tooltip should explain the term in one or two sentences; a clickthrough should show evidence, not a fabricated conclusion. Keyboard and touch use matter alongside hover.
- **Top-level layout:** Prefer a small action-oriented summary over counters without an interpretation. Preserve a visible capture time, source, and coverage/unknown state. The mockups' example health, backup, update, workload, and chat claims must never appear as Goliath facts without corresponding local evidence.

The feedback is captured for later design and implementation. The current static dashboard, snapshot format, scheduled checker, PerfMon policy, and listener approval behavior are unchanged by this document.

## Chat-first review — 2026-09-24 EDT

Status: **owner feedback and implementation backlog; the items below are not implemented by this document.** The owner reports that chat is very slow, asks where the useful parts of the dashboard went, wants a troubleshooting log and simple file-based memory, wants fewer approval interruptions (for example, confirmation on delete), and wants proactive checks such as reviewing event-log warnings and errors. The owner also found the check list below an answer unintelligible:

```text
Inventory: OK · 2026-09-24 06:26:38 UTC
Recent event health: DEGRADED · 2026-09-24 06:26:40 UTC
Process details: UNKNOWN · 2026-09-24 06:26:49 UTC
Resource sample: DEGRADED · 2026-09-24 06:28:04 UTC
```

These are the owner's displayed capture timestamps (02:26–02:28 EDT), **not** measured step durations or proof of the cause of delay. The list currently mixes collection coverage with diagnostic findings: `OK` can mean a check collected data, not that the machine is healthy; `DEGRADED` can mean a result is partial; `UNKNOWN` means the check cannot support a conclusion. The answer view drops the underlying reason and evidence link. Investigate those exact results from retained local evidence if available; do not infer a fault from the labels alone.

### Current product gap

The chat page has the conversation, saved snapshot coverage, and example questions. The fuller point-in-time view is still a separate generated `evidence/dashboard.html`: it contains alerts and recent changes, six inventory sections with saved-record drilldowns, a working-set memory sample, and a small TCP listener section. The chat does not surface these as an action-oriented overview. The static page has no live CPU or resource trends. Event health currently queries selected System/Application event IDs on demand; scheduled `tick` does not run it. The browser transcript is temporary, and there is no bounded chat-phase troubleshooting log or explicit file-backed conversation memory. These are current behavior, not completed roadmap items.

### Narrow live cost check — 2026-09-24 02:35 EDT

One `node.exe` process whose command line matched `scripts/chat-server.js` (PID 19300, created 02:24:29 EDT) had one vendor `codex.exe` child (PID 36700, created 02:24:35 EDT; parent PID 19300). Their working sets were 52.5 MiB and 124.6 MiB respectively; each accumulated **0 CPU seconds over a 2-second idle sample**. The exact `GoliathCaretaker-R1` scheduled task last ran at 02:30:30 EDT with native result `0`, with its next run then scheduled for 02:45:29 EDT. No process or task was changed. This short idle check does not measure an active chat turn, a full day, or system-wide slowdown; phase timing and representative load measurements remain open.

### Next implementation order and done proof

| Priority | Slice | Done proof |
| --- | --- | --- |
| 1 | **Explain and measure chat speed.** Record bounded phase timings for model startup, each precheck, model turn, tool calls, and reply; show progress while waiting. Measure normal-use wall time, CPU, and memory on this host. Slowdown prechecks currently run resource and event queries serially before the turn; investigate their cost and repeated work before changing them. Stream answer text if the app-server path supports it. Compare Luna `xhigh` with lower supported efforts using the same representative question, without changing the requested default silently. | A reproducible timing breakdown, idle and active resource measurements, and a visible response before the full turn finishes where supported; no unmeasured speed claim. |
| 2 | **Make the chat page the useful dashboard.** Put concise, source-linked current/saved cards near chat for alerts needing attention, recent changes, inventory coverage, relevant resource evidence, and event findings. Keep the full snapshot records as drilldowns. Never populate a card from a mockup, and show capture time and `UNKNOWN` for missing evidence. Do not run heavy checks merely because a page opens. | User can reach the relevant record from the chat page and distinguish live checks from saved snapshot data without running a separate script. |
| 3 | **Translate check metadata into plain English.** Under each answer show which checks ran, what was found, what was incomplete, and why; put technical status, exact time, and source in an expandable evidence detail. Use readable local EDT/EST time with UTC preserved in data. A warning or partial collection must not look like a machine-health verdict. | The four-line example above would explain each outcome and its limit, or show an explicit unavailable reason; no unexplained `OK`/`DEGRADED`/`UNKNOWN` list. |
| 4 | **Reduce approval friction with explicit risk rules.** Design and test a mechanical policy for bounded local read-only checks and safe routine operations, with reviewable scope and audit. Confirm destructive delete/overwrite and other high-impact or external actions against their exact targets and effects; continue to block self-elevation and unknown ownership. Do not switch a full-access Codex turn to blanket trust just to remove prompts. | A user can complete a normal diagnostic without approving each read command; a destructive test still requires an exact confirmation; denied or malformed requests fail closed. Document the precise rule before enabling it. |
| 5 | **Add a low-cost proactive event digest.** Analyze new, relevant warnings/errors from supported Windows logs with a bounded query, cursor, deduplication, severity, source and coverage. Start with the existing high-signal categories, then widen only where useful. Show an understandable finding and record link; distinguish a quiet interval from an unreadable or truncated log. Decide whether to add this to the existing checker only after measuring its cost. | A seeded warning/error appears once with reason and source; a missing log is `UNKNOWN`; repeated runs do not repeatedly scan or alert on the same event, and the checker stays within a measured budget. |
| 6 | **Keep a private troubleshooting trail and small memory.** Record every chat turn, check, tool/action attempt, approval decision, and outcome with phase times, coverage, error class, child lifecycle, and evidence references. Keep a bounded private question/answer history under ignored `evidence/`; keep raw command arguments, file contents, credentials, and private event text out of the routine operational log. Store concise, user-reviewable incident notes and workload explanations in files; keep desired policy in `config/caretaker.json`, observed state under ignored `evidence/`, and Git as development history. Define retention, redaction, and export before logging. | After a slow or failed turn, local records explain what was asked, where time went, and what was checked, without exposing sensitive content in Git or growing without bound; notes survive a chat restart and can be corrected or removed. |

### Guardrails for this backlog

Keep the checker task and PerfMon-off policy as they are until a specific measured change is reviewed. Avoid a resident chat service, duplicate supervisor, broad event-log sweep, or continuous polling. Existing file-based decisions (`config/caretaker.json`) and ignored snapshots/change journal should be reused; do not create a second desired-state authority. Project documentation and this backlog do not themselves change chat approval behavior or authorize unrelated Windows actions.
