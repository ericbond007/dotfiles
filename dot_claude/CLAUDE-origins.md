# CLAUDE.md — origins (why the rules exist)

Companion to `~/.claude/CLAUDE.md`. **Not auto-loaded.** Each section below is an incident narrative that used to sit inline under a rule; the rule itself stays in CLAUDE.md with a pointer of the exact shape used throughout that file: an arrow, `origin:`, the path `~/.claude/CLAUDE-origins.md` in backticks, a section sign, and the FULL heading below in double quotes. Moved 2026-11-03 (aiImprove audit §3.3; Dave's pick: option 2 with pointers). "Check your memory" still means CLAUDE.md; open this file when a rule's *reason* is in question. New rules enter CLAUDE.md as rule + one-line origin + pointer; their narrative goes HERE, not inline. `~/.claude/hooks/tests/claude-md-pointers.test.sh` checks that every pointer resolves to a heading in this file.

## EXECUTE THE PLAN YOU WROTE — 2026-07-24, the wanda maintenance window

*Moved from CLAUDE.md § "EXECUTE THE PLAN YOU WROTE", 2026-11-03.*

**Origin:** 2026-07-24, the wanda maintenance window. I drafted a 10-step plan whose step 3 was *"Open a second root ssh session and leave it open"* — written specifically because `openssh` was in the 601-package upgrade set. Dave approved the plan. I then executed from improvisation rather than from the plan, skipped step 3, and when openssh was replaced mid-transaction sshd stopped accepting new connections — costing the only management channel into wanda for the rest of the upgrade. An **already-established** ssh session survives sshd being replaced (only *new* connections fail), so the skipped step was precisely and solely the thing that would have prevented it. The plan was correct; the execution ignored it.

## CI gates are HARD — 2026-06-11, jailBird PR #87

*Moved from CLAUDE.md § "CI gates are HARD", 2026-11-03.*

Origin: 2026-06-11, jailBird PR #87 — a stray script rode a jj snapshot into a PR, failed a CI gate the local set didn't replicate, and a blind command chain merged anyway. Master went red. Dave's verdict: "CI gates should be hard. If the build fails, we do not merge. Stop and solve it."

## Evidence discipline, mode 4 — 2026-08-17, the drift checker

*Moved from CLAUDE.md § "Evidence discipline (mode 4)", 2026-11-03.*

**Origin, 2026-08-17.** I wrote a drift checker comparing each container's baked env against its `env_file`. It ignored that compose `environment:` *overrides* `env_file` by design, so **three of its four findings were false**. I had "tested" it — but only in the confirming direction (hide the allowlist, findings reappear). I never asked whether it stayed silent on something known-correct. Those false findings became a ticket, template edits, unit-conversion decisions, and a wrong story told to Dave twice. Verifying a single finding by hand would have collapsed it in two minutes. Another agent caught it, not me.

## Don't assume my intent on a ticket — 2026-06-13, #1240

*Moved from CLAUDE.md § "Don't assume my intent on a ticket", 2026-11-03 (it had physically sat under the Monitoring heading since it was written; the pointer now sits at the end of the ticket section).*

Origin: 2026-06-13, **#1240** — ticket said "investigate the root source of MariaDB `Aborted_connects` and reduce it." I correctly traced it to a Uptime Kuma port-monitor probing :3306 every 60s — then on my own judgment **disabled that monitor and closed the ticket**. Disabling part of Dave's monitoring was his decision to make. The investigation was wanted; the unilateral fix was the overstep. Same epistemics as the rules above: my judgment doesn't substitute for Dave's explicit choice.

## The Stop gate that never fired — 2026-06-27 → 2026-10-18

*Moved from CLAUDE.md § "A SEPARATE review is mandatory", 2026-11-03. The proof record ("Fixed and proven end to end 2026-10-18 …") and the lesson (class 9 of "Plans that LAND") stay in CLAUDE.md; only the history sentence lives here.*

**History:** from 2026-06-27 to 2026-10-18 the gate emitted the wrong JSON shape (the PreToolUse form) and never blocked once — not a single "Stop hook feedback:" injection in any transcript on flattop; the rule was enforced only by discipline.

## The Atomic Arch AUR campaign — 2026-06

*Moved from CLAUDE.md § "Inspect AUR PKGBUILDs before installing", 2026-11-03. CLAUDE.md keeps the rule and the shape of the campaign (adopted/orphaned packages, largely via updates); this is the full sentence with the payload and the victim count. The IOC battery and the 2026-06-15 baseline sweep are in the `fleet-security-auditor` agent.*

The 2026-06-11 **"Atomic Arch" / atomic-lockfile** campaign pushed malware (Rust infostealer — Discord/GitHub-PAT/npm/Slack/Teams/SSH/Vault/Docker creds + browser cookies — plus a cryptominer, an eBPF rootkit, and systemd persistence) through adopted/orphaned packages largely via **updates** — so both fresh installs and routine upgrades are vectors; by 2026-06-15 the consolidated victim list had grown to **~1,619 packages**.

## One numbering sequence per message — 2026-10-28 → 2026-11-11

*Promoted 2026-11-11 from jailBird's project memory, `~/.claude/projects/-home-eric-projects-jailBird/memory/feedback_unique_choice_numbers.md` on flattop (per-host, not synced), which sessions outside jailBird never loaded.*

- **2026-10-28, jailBird.** I asked two decisions in one message, under headings "Decision 1: ruling 19" (options 1–3) and "Decision 2: how to run the build" (options 1–2). Dave: *"are you asking me two questions with the same numbers? how in the hell am I supposed to answer that?"* He answers by number, so a repeated number makes his answer ambiguous and costs a round trip.
- **2026-11-10, jailBird.** To avoid an option 11 that existed only in the spec, I numbered one list's options `9.`, `10.`, `13.`. Dave's screen showed 9, 10, **11** (a Markdown ordered list keeps only its first number), and he answered with 11 three times while I asked which option he meant. Hence "a new option takes the next number in its own list".
- **2026-11-11, pzServer.** Because the rule lived only in jailBird's memory, a pzServer session asked two questions under bold headings "1." and "2.", with options 1–4 and 1–3. Dave: *"lol you gave me two sets of the same number questions, ask those again. I thought we had a claude rule that says to stop doing that?"* Promoted to the fleet CLAUDE.md the same day.
