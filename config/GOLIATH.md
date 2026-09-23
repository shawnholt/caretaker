# Goliath context and preferences

This is the small human context for the caretaker. Machine-readable desired/deployment policy belongs in [`caretaker.json`](caretaker.json); observed snapshots and logs belong under [`../evidence/`](../evidence/). This file records user-provided preferences; it is not proof of current hardware, installed software, or system state.

## Verified facts

- No machine-specific adapter, driver, backup-result, or workload facts have been verified by this note.
- Use the caretaker's live local queries and supported result sources for current state. Missing evidence remains `UNKNOWN`.

## User preferences

- Goliath is a personal Windows development/hobby workstation. Favor useful answers with low background load, simple maintenance, and low cognitive overhead; avoid enterprise monitoring stacks.
- Prefer native structured Windows APIs, then a mature command-line tool, then a small borrowed pattern. Add custom code only for Goliath-specific state. Do not add a process manager, supervisor, resident agent, dashboard, or broad MCP stack without a demonstrated need.
- Intel Wi-Fi/Ethernet drivers without Killer optimization or telemetry is a preference, not a verified installed adapter/driver fact. The installed hardware and driver state have not been audited here.
- Duplicati remains the owner's backup system. The caretaker may report per-job results through a supported local source; it must not change jobs, schedules, destinations, or retention. Backup health remains `UNKNOWN` until a supported result source proves the last success/failure.
- Observing a process repeatedly does not make it wanted or authorize stopping it. Use a small workload record and occasional review prompts; do not create a manual CMDB.

## Current-state limits

Do not copy live observations into this preference note. Keep changing machine state in snapshots and logs under ignored `evidence/`; keep desired deployment identities and limits in `caretaker.json`.
