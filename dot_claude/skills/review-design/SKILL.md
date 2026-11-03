---
name: review-design
description: Use BEFORE presenting any non-code artifact as done, ready, or for approval — a spec, design, implementation plan, runbook, cutover sequence, monitoring rule set, hook, skill, CLAUDE.md change, or a finding bound for a ticket, wiki page or memory file. Runs the fleet's standard COLD review (a reviewer who did not write it, Opus or better) with the nine-class "Plans that LAND" checklist, then fix → narrow re-review until a pass reports nothing material. Dave's fleet mandate (2026-10-18): this runs automatically, every time, without being asked; the Stop gate blocks "done" on design/plan/ops edits until it has.
---

# Review a design, plan, runbook, or finding

**Why this exists.** On 2026-10-18 one spec went through five cold reviews that found 17, 14, 13, 5 and then only nits — six blockers in total, none of which self-review caught. Dave: *"every time we write a plan, we review it, and there are problems. that should not happen. we should automatically review everything we do, so that I do not have to constantly remind you."* So: the review is part of writing the artifact, not a step Dave asks for.

## When

Before the FIRST time you present any of these as done / ready / for approval, and again after any fix that changes it:

- a spec or design document (`docs/superpowers/specs/**`, any `*-design.md`)
- an implementation plan (`docs/superpowers/plans/**`)
- a runbook, cutover sequence, deploy procedure, README that encodes a procedure
- systemd units/timers, env templates, compose changes, Prometheus rules, hook scripts, skills, CLAUDE.md rules
- a diagnosis / root cause / tool output about to become a ticket, wiki entry, or memory file

Code gets `/code-review` (or a code-reviewer agent) instead; a change that is both gets both.

## Proportionality (so the gate does not turn a typo into an Opus loop)

- **Full lane** — anything touching a deploy, real money, a safeguard, a secret, a schema, or a sequence of steps on a live host: all eight classes, two passes minimum, loop until a pass reports nothing material.
- **Small lane** — a wording fix, a README paragraph, a one-line unit or rule tweak, a skill edit: ONE pass, only the checklist classes that apply (say which), narrow brief. If the reviewer finds a blocker, you are in the full lane.
- **Trivial** — a typo or a scratch file: use the positional override the gate names (`echo claude-review-ok-<session>`), and say in chat that you did and why.
- **Exit condition**: the loop ends when a pass reports nothing material, OR after three passes with no blocker — then present the residual nits to Dave as a list instead of spinning another pass.

## How

1. **Name the artifact and what it touches.** List the files/scripts/units it reuses or changes, the live systems it will run against, and the owner decisions that are already fixed (so the reviewer does not relitigate them).
2. **Dispatch a cold reviewer** with the Agent tool: `subagent_type: Plan` (it has no Edit/Write tools; it still has Bash and ssh, so read-only remains a brief instruction, not a guarantee), `model: opus`, `description` containing the word **review** (the Stop gate keys on the dispatch), prompt built from `references/brief.md` — fill every bracketed slot; in the full lane never trim the nine-class checklist. The brief tells the reviewer: read-only, spawn no agents, spend no credits, verify against the code/host rather than the prose. Give it read-only ssh instructions if the artifact targets a fleet host. This skill depends on the Agent tool and an Opus-class model; on a host without them, say so and get a human review instead.
3. **Verify each reported blocker yourself against the code or host before adopting it** — reviewers are confidently wrong sometimes. Adopt what verifies; push back in the next brief on what does not.
4. **Fix the artifact.** For specs and plans, bump the status line (rev N, what changed, which review) and keep the facts section in sync with any corrected fact; for units, templates, hooks and CLAUDE.md, record the review in the commit message instead.
5. **Re-review, narrowly:** a fresh agent, briefed on the previous findings and told to confirm each is resolved and to hunt only the changed mechanisms. Loop 4→5 until a pass reports **nothing material** (nits only). Expect diminishing returns: 17 → 14 → 13 → 5 → nits is the measured shape; two passes is the floor for anything touching deploys, money or safeguards.
6. **Only then present it**, with the same breakdown every time: what each pass found, what you verified, what changed. Present AFTER the findings are in: the gate counts the reviewer's dispatch, so finishing before its report arrives is the honour-system part.

## The nine classes the brief checks (from the fleet CLAUDE.md "Plans that LAND")

1. procedures copied from the live script, never from memory (`file:line`)
2. every safeguard: what benign events also trip it?
3. every alert traced event → log → metric → rule → Alertmanager → page, with the step that proves it — proven only UP TO Alertmanager, silenced first (fleet CLAUDE.md, class 9 "Exception for alerts": a proof never reaches Dave's inbox, silence first; mechanics in the `wiring-fleet-monitoring` skill § 6)
4. every classifier has a default branch, and the default is the serious case
5. every step: concurrent actor / reboot / what does rollback need that this destroys
6. every API/SDK fact cited or probed; no VERIFY left before planning
7. every threshold above the measured legitimate maximum
8. consistency pass after each revision
9. every safeguard (gate, alert, cap, hook) observed firing once, end to end, with the record that proves it named — for an ALERT, "end to end" stops at Alertmanager (`status.state: suppressed` under a narrow silence + `amtool config routes test --verify.receivers`), never Dave's inbox; a test that passes against the wrong contract is worse than none

## Don'ts

- Don't self-review and call it reviewed. Don't reuse the agent that wrote the artifact.
- Don't present an artifact "for a look" before the review has run — that is the reminder Dave no longer wants to give.
- Don't skip the loop because the first pass "looked minor"; the blockers above were found on passes 2, 3 and 4.
- Don't let the reviewer spend money or change state: read-only, no API credits, no edits.
