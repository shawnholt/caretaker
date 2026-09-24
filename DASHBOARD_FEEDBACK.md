# Dashboard feedback — 2026-09-23

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
