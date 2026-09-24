# AGENTS.md — Limit Counter

Read [Work-claim lifecycle](docs/agent-doctrine/WORK_CLAIM_LIFECYCLE.md)
in full before repository mutations or marker actions. It is the shared
TaskWraith Suite concurrency contract.

Check this repository's Git status and live claims before edits. Preserve peer
dirt, use narrow 20-minute claims, and commit explicit paths through a private
index when peers may be active. Never infer inactivity from missing markers.
Keep formatting scoped to the intended change.

Follow the user's artifact-first release plan. Source changes, successful tests
and local builds do not authorize publishing, tagging or installation. Keep
private paths, credentials, recovery records and machine-specific configuration
out of tracked documentation and distributable artifacts.

The user's task and host permissions remain authoritative. Do not remove or
restrict user-facing capabilities without approval of that exact change.
