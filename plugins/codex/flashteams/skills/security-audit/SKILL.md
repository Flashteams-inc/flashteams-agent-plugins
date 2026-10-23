---
name: security-audit
description: Use when the person asks for a security audit or a security scan of this repository, or to check the code for leaked secrets and keys, injection and other vulnerabilities, unsafe infrastructure files or vulnerable dependencies. Runs gitleaks, opengrep with FlashTeams' rules and Trivy on this computer, reviews what they find, and records the results in FlashTeams.
---

# Security audit

Scan this repository on this computer for secrets and vulnerabilities,
judge what the scanners find, write a report, and record it in FlashTeams.
This is a laptop scan: it shows beside the scan FlashTeams runs, and never
replaces it.

Rules for the whole audit:

- **Never print or repeat a secret's value**: not in a message, the
  report, the notes or a command. The helper's `show` prints `[hidden]` in
  its place. Do not open a secret's line with any other tool (cat, grep,
  sed or your file reader). Judge a secret by its file, its rule, the
  lines around it, and whether `show` says the hidden text has placeholder
  words.
- Never commit anything. Do not change code unless the person asks.
- Keep the work folder and the report outside the repository.

## The helper

Every step runs `flashteams-scan.pl`, which comes with this plugin, in the
`scan` folder two levels above this skill's folder:

- Claude Code shows this skill's base directory when it loads the skill.
  The helper is `<base directory>/../../scan/flashteams-scan.pl`.
- Codex shows the path of this `SKILL.md`. The helper is
  `<the folder holding SKILL.md>/../../scan/flashteams-scan.pl`.

Below, `HELPER` stands for that full path. Write it out in double quotes in
every command, as `perl "HELPER" ...`, since shell variables do not last
from one command to the next.

The helper reaches FlashTeams through the `flashteams` command that Flash
Console provides. When it says the command is not here (exit 3, or 127
from the shell), use the FlashTeams MCP tools instead if you have them
(from the optional `flashteams-mcp` plugin), with the same names and
arguments. With neither, do the scan and the report here, and tell the
person the results were not sent to FlashTeams.

In Codex, `install`, `rules`, a full scan and `send` need the network or
Flash Console's socket: run them outside the sandbox when Codex asks.

## Steps

1. **Agree what to scan.** Unless the person already said, ask which folder
   (the whole repository by default) and which mode:
   - **quick**: secrets and FlashTeams' code rules;
   - **full**: also infrastructure files (Dockerfiles, Terraform,
     Kubernetes and the like) and dependency vulnerabilities, which
     downloads Trivy's vulnerability database (several hundred MB the
     first time).

   Pick the work folder once: run `echo "${TMPDIR:-/tmp}"` and use
   `<that>/flashteams-scan/<repository name>-security-<date>-<time>`, for
   example `/tmp/flashteams-scan/shop-security-20261022-101500`, written
   out in every step. Run every command from inside the repository.

2. **Check the scanners.** `perl "HELPER" doctor`. It lists gitleaks,
   opengrep (semgrep stands in when opengrep is missing), Trivy and git,
   and for each missing one the exact ways to install it.

3. **Offer to install what is missing, and wait for a yes.** Tell the
   person what each missing scanner checks and the choices `doctor`
   printed: `perl "HELPER" install <tool>...`, which downloads the version
   FlashTeams uses into `~/.flashteams/tools/bin` and checks it against a
   pinned checksum, or Homebrew on a Mac. Run only what they agree to. If
   they say no, carry on: the scan records each missing scanner.

4. **Get FlashTeams' rules.** `perl "HELPER" rules` asks FlashTeams for
   them (the `get_scan_rules` tool, which only reads), downloads them,
   checks their checksum, and prints the rules folder on its last line.
   With only the MCP tools: call `get_scan_rules`, then
   `perl "HELPER" rules --url '<url>' --sha256 <sha256>` with its answer
   straight away (the link works once, within two minutes). If neither works, go on without
   rules: gitleaks and Trivy still run with their own rules, and opengrep
   is recorded as skipped.

5. **Run the scan.**

   ```sh
   perl "HELPER" run --kind security --mode quick --path <folder> --rules "<rules folder>" --out "<work folder>"
   ```

   Leave `--path` out for the whole repository and `--rules` out without
   rules. On a large repository this takes minutes: give the command a
   long timeout (10 minutes or more), or run it in the background and
   wait for it.

6. **Read the summary.** It lists each tool (ran, skipped, missing or
   failed), the counts, and the 40 most severe findings as numbered lines,
   such as `#3 high security src/api/user.ts:88 ...`. Every finding is in
   `<work folder>/findings.json`, numbered in the same order from 1.

7. **Look at the ones that matter.** `perl "HELPER" show --out "<work folder>" --ids 1,2,5`
   prints each finding in full with the code around it. Show every
   critical and high finding and anything that looks doubtful, open the
   code (but never a secret's line) to see how it is used, and decide:
   real, a false positive, or real but less serious than its severity.

8. **Write the notes**, `<work folder>/notes.json`:

   ```json
   {
     "dismiss": [3, 7],
     "notes": {
       "12": {"detail": "Why it matters in this code.", "recommendation": "How to fix it here."}
     },
     "add": [
       {"category": "security", "severity": "high", "title": "Admin routes have no auth check",
        "path": "src/routes/admin.ts", "line": 10, "rule": "agent.security.missing-auth",
        "detail": "...", "recommendation": "..."}
     ]
   }
   ```

   `dismiss` takes false positives out (say why in the report). `notes`
   replaces a finding's detail and recommendation with yours, for what
   matters. `add` is for problems you found yourself while reading the
   code; category is one of secret, security, hotspot, sql, iac,
   dependency or architecture, and severity one of critical, high,
   medium, low or info. Numbers are the finding numbers from the summary.

9. **Write the report**, `<work folder>/report.md`, in plain language:
   what was scanned (folder, branch, commit, whether there were changes
   not committed, mode, rules version), which tools ran and which did not
   and why, the counts, the findings that matter with `file:line`, why
   each matters and how to fix it, a short fix-first list, what was
   dismissed and why, and what this scan cannot see (the git history, as
   gitleaks reads only the files as they are now; how the code runs;
   logic and permission flaws no rule knows; anything outside the folder;
   in quick mode, infrastructure files and dependencies). Write a short
   summary of a few sentences in `<work folder>/summary.md` (at most
   4,000 characters).

10. **Build the payload.**

    ```sh
    perl "HELPER" payload --out "<work folder>" --kind security --summary-file "<work folder>/summary.md" --report-file "<work folder>/report.md" --notes "<work folder>/notes.json"
    ```

    It writes `<work folder>/payload.json` with git's facts about the
    checkout (the remote address without any user name or password, the
    branch, the commit) and no folder of this computer.

11. **Record it in FlashTeams.** `perl "HELPER" send --out "<work folder>"`
    runs `record_code_scan` through the `flashteams` command and prints
    its answer. With only the MCP tools, call `record_code_scan` with the
    fields of `payload.json` as its arguments.
    - Exit 0: the answer has `scan_id`, the counts, `new_since_last`,
      `fixed_since_last` and a `url`.
    - Exit 1 with `"reason": "repository_not_linked"`: FlashTeams does not
      know which product this checkout belongs to. Show the person the
      `products` in the answer, ask which one, and send again with
      `--product-id <id>` (with MCP, add `product_id`).
    - Exit 1 otherwise: read the reason and tell the person.
    - Exit 3 or 4: tell the person what the message says.
    - Exit 5: the scan may have been recorded. Do not send it again on
      your own; tell the person.

12. **Tell the person** the counts by severity, what is new and what was
    fixed since the last scan, the link, and where the report is. Offer to
    save a copy of the report into the repository; do it only if they
    want one.

13. **Offer next steps, and wait for a yes for each.**
    - Tasks for the critical and high findings, assigned to the person:
      `flashteams file_scan_tasks --scan_id <scan id> --min_severity high`,
      or for chosen findings `--fingerprints <fingerprint>` (from `show`
      or `findings.json`), once per finding. With MCP, call
      `file_scan_tasks` with the same arguments.
    - Fixing them. Change code only after they agree, and do not commit.
