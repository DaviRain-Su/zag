---
status: active
id: D-013
title: Live self-modification runtime explored as fixed Zig kernel + supervised Scheme prototype track
date: 2026-08-13
---

# D-013 — Live runtime prototype track

## Decision

Zag explores live self-modification on an **isolated prototype track**:

- A **fixed Zig supervisor kernel** owns the journal, generations,
  credentials, terminal, and recovery path.
- The mutable live image is a **Chez Scheme subprocess** under supervision,
  following the process direction of [D-010](./D-010-extension-tiers-and-process-protocol.md)
  E2.
- All durable self-modification goes through **kernel primitives**
  (`kernel.redefine` / `kernel.inspect` / `kernel.commit` / `kernel.discard`).
  Persistence is a privilege, not a ban on Scheme mutation: only
  kernel-tracked bindings survive restore.
- **Generations are declarative** — base image plus replay script, hashed and
  parented. Heap dumps are not used; the journal is an audit log, not a
  replay log.
- Spike code lives in `spikes/live-runtime/` with its own build, outside
  `packages/` law and outside every maturity claim.

This is **not** a new extension tier and **not** a product commitment.
Productization requires later separate decisions informed by spike
measurements.

## Why

- A systems-language host cannot rewrite its own compiled code. D-010 already
  rejected embedding Lua/QuickJS/Bun-style script VMs for extensions. A
  supervised process keeps the host TCB physically intact while giving the
  agent a genuinely live image.
- [Autolith](https://github.com/lambda-symbolics/autolith) (pure Common Lisp)
  demonstrates the model: its real safety net already lives outside the image
  (stable launcher, pristine recovery image, replay-script mutation history),
  and it keeps declarative replay scripts authoritative even though SBCL heap
  dumps exist. See the
  [analysis](../../plan/analysis/2026-08-13-autolith-live-runtime-analysis.md).
- The split buys properties the pure-Lisp design only gets by discipline:
  credentials never enter the mutable heap; terminal and journal survive
  image crashes; turn ordering is enforced by the supervisor.

## Consequences

- `spikes/live-runtime/` is exempt from packaging law and maturity scoring;
  nothing in `packages/`, `docs/maturity.md`, or `chapters/` changes.
- If the spike succeeds, later decisions must cover: introspection protocol
  fidelity, macro/dependency semantics for durable redefinition, promotion
  from spike to a real package, and maturity gates.
- Existing contracts (Phase H, SDK, headless, D-010 tiers, D-011 Core
  boundary) are untouched.

## Related

- [Autolith → Zag live-runtime analysis](../../plan/analysis/2026-08-13-autolith-live-runtime-analysis.md)
- [live-runtime-spike-001](../../plan/tasks/live-runtime-spike-001.md)
- [D-010](./D-010-extension-tiers-and-process-protocol.md)
- [D-011](./D-011-thin-agent-core-boundary.md)
- [D-012](./D-012-complete-local-coding-agent-target.md)
