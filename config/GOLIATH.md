# Goliath context and preferences

This is the small human context for the caretaker. Machine-readable desired/deployment policy belongs in [`caretaker.json`](caretaker.json); observed snapshots and logs belong under [`../evidence/`](../evidence/). This file records user-provided preferences; it is not proof of current hardware, installed software, or system state.

## Verified facts

- No machine-specific adapter, driver, backup-result, or workload facts have been verified by this note.
- Use the caretaker's live local queries and supported result sources for current state. Missing evidence remains `UNKNOWN`.

## User preferences

- Goliath is a personal Windows development/hobby workstation. Favor useful answers with low background load, simple maintenance, and low cognitive overhead; avoid enterprise monitoring stacks.
- Prefer native structured Windows APIs, then a mature command-line tool, then a small borrowed pattern. Add custom code only for Goliath-specific state. Make a useful on-demand dashboard a near-term primary interaction surface while keeping idle resource use low. Do not add a competing process manager, supervisor, resident agent, or broad MCP stack.
- Use AI reasoning when a question benefits from it. Prefer direct Codex app-server or SDK integration with ChatGPT-managed authentication for dashboard conversation. Caretaker must not depend on `codex-mcp-bridge` or require a separate API key for ordinary questions.
- The two dashboard mockups shared on 2026-09-23 are visual inspiration for hierarchy and interaction, not literal copy or evidence. Never show their example metrics, issue counts, backup/update claims, workload purposes, or chat messages as Goliath facts.
- Intel Wi-Fi/Ethernet drivers without Killer optimization or telemetry is a preference, not a verified installed adapter/driver fact. The installed hardware and driver state have not been audited here.
- Duplicati remains the owner's backup system. The caretaker may report per-job results through a supported local source; it must not change jobs, schedules, destinations, or retention. Backup health remains `UNKNOWN` until a supported result source proves the last success/failure.
- Observing a process repeatedly does not make it wanted or authorize stopping it. Use a small workload record and occasional review prompts; do not create a manual CMDB.

## Current-state limits

Do not copy live observations into this preference note. Keep changing machine state in snapshots and logs under ignored `evidence/`; keep desired deployment identities and limits in `caretaker.json`.
