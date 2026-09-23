# Task: 48-Hour Windows Event Log Investigation

## Objective
Autonomously analyze Windows Event Logs for the last 48 hours and identify real issues (errors, instability, hardware, driver, power, update, and service failures). Minimize noise and surface what actually matters.

## Scope
- Time window: last 48 hours, local system time.
- Primary focus: System stability, hardware, drivers, power, updates, services, and networking.

## What to Do
1. Query Windows Event Logs (non-admin where possible):
   - System
   - Application
   - Microsoft-Windows-Kernel-Power
   - Microsoft-Windows-WHEA-Logger
   - Microsoft-Windows-DriverFrameworks-UserMode/Operational
   - Microsoft-Windows-WindowsUpdateClient/Operational
   - Microsoft-Windows-DeviceSetupManager/Admin
   - Microsoft-Windows-NetworkProfile/Operational

2. Cluster events by Provider + Event ID.

3. Rank clusters by:
   - Severity (Critical/Error first)
   - Frequency / recurrence
   - Association with instability (crashes, unexpected shutdowns, driver resets, disk or hardware errors).

4. Ignore known noise unless correlated:
   - DistributedCOM 10016
   - Transient service restarts that self-recover

5. For the most important clusters:
   - Summarize what the event means in plain language.
   - Look up the event meaning and common causes using your internal knowledge.
   - State likely impact and confidence.
   - Propose diagnostic next steps (commands only, no fixes yet).

## Evidence and Logging
- Log all commands and outputs to `diag_log.txt` per AGENTS.md.
- Do not apply any system changes.
- If admin access is required for deeper inspection, generate an admin script and ask for approval.

## Output to User
- Short executive summary: what looks real vs noise.
- Ranked list of issue clusters with explanations.
- Clear next diagnostic steps.

## Constraints
- No system changes without approval.
- No elevation unless explicitly requested.
- Operate only within the project folder.

