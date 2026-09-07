# Tankster AI

AI-native product studio, pre-revenue and in development — building agent-operated
infrastructure and tools, with AI agents doing the work and one human holding approval.

Founded and run by [Rishi Tank](https://rishitank.co.uk) in London. Everything here is his
work; the studio owns it and runs it in its own estate.

## Open infrastructure

The tools that make agents safe to run are public. The products built on them are not.

| Repository | What it does | What it honestly is not |
|---|---|---|
| [`grit`](https://github.com/TanksterAI/grit) | Policy gateway for MCP tool calls: undeclared tools denied, every path resolved before it is checked, snapshot-and-rollback before anything mutates, AES-256-GCM credential store. | Kernel sandboxing. It checks arguments, not syscalls. |
| [`adlc`](https://github.com/TanksterAI/adlc) | Adversarial verification for tool calls, judged by filesystem state diffs — never by what the tool said it did. Containment cases probe one directory above the workspace. | A correctness verifier. It judges which paths changed, not whether their content is right. |
| [`agent-egress-proxy`](https://github.com/TanksterAI/agent-egress-proxy-clean) | Fail-closed perimeter for outbound model traffic: PII redaction, per-request token and cost ceilings, circuit breaker, structured decision logs. Rust. | A guarantee. Redaction is pattern-based. |
| [`stratum`](https://github.com/TanksterAI/stratum) | Extraction half of an agentic data lake: permissively-licensed sources only, exact dedup, size-bounded, JSONL manifest. | A crawler. One source, fetched by explicit title, per its published etiquette. |
| [`docket`](https://github.com/TanksterAI/docket) | Human-review half: resumable approve / relabel / reject queue, append-only decisions. | A web UI, or a preference-pair constructor. |

Together the first three, with the studio's private control plane, form the
[Robustness Layer](https://rishitank.co.uk/robustness-layer) — four components, each answering
one question the others do not trust it to have answered: *may the agent act? what can it touch?
what left the machine? did containment hold?* That page includes a self-assessment against the
UK NCSC's agentic-AI guidance, and a live demo that sends text through a deployed instance of
the egress proxy and shows what the vendor received.

## How the repositories are built

Every repository states what it is not, in its README, before it says anything else it can do.
Tests run fully offline against trait-injected fakes. CI runs lint, tests and Clippy at
`-D warnings`, plus gitleaks, osv-scanner and cargo-audit on every push. Architecture decisions
that cost something to make are recorded as ADRs next to the code.

## Status

Pre-revenue. No customers, no production traffic. The services are deployed to a staging estate
on a single host. Presented as evidence of what the studio can build, not as available
capability.
