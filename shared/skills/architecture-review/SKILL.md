---
name: architecture-review
description: Use when the person asks for an architecture review of this repository, or for an overview of how the codebase is built: its main parts, how data flows, where the auth and data access boundaries are, dependency cycles, modules everything leans on, dead code, coupling across layers, and risky or hard-to-reverse choices. Uses the product's FlashTeams code map when there is one, otherwise reads the repository, and records the findings in FlashTeams.
---

# Architecture review

Explain how this system is built and where its risks are, so a new
engineer can understand it, and record the risks in FlashTeams. No
scanners run: you read the code and, when FlashTeams has one, the
product's code map.

Rules for the whole review:

- Never print or repeat a secret's value you come across; say where it is,
  never what it is.
- Never commit anything. Do not change code unless the person asks.
- Keep the work folder and the report outside the repository.

## The helper

The last steps run `flashteams-scan.pl`, which comes with this plugin, in
the `scan` folder two levels above this skill's folder:

- Claude Code shows this skill's base directory when it loads the skill.
  The helper is `<base directory>/../../scan/flashteams-scan.pl`.
- Codex shows the path of this `SKILL.md`. The helper is
  `<the folder holding SKILL.md>/../../scan/flashteams-scan.pl`.

Below, `HELPER` stands for that full path. Write it out in double quotes in
every command, as `perl "HELPER" ...`.

FlashTeams is reached through the `flashteams` command that Flash Console
provides (see the flashteams skill: `flashteams help <tool>` shows a tool's
arguments). When the command is not here (exit 3, or 127 from the shell),
use the FlashTeams MCP tools instead if you have them, with the same names
and arguments. With neither, read the repository, write the report here,
and tell the person the results were not sent to FlashTeams.

## Steps

1. **Agree the focus.** Unless the person already said, ask what matters
   most to them, for example API contracts, the data model, security
   boundaries, coupling between parts, or performance. Review everything,
   and go deepest there. Pick the work folder once: run
   `echo "${TMPDIR:-/tmp}"` and use
   `<that>/flashteams-scan/<repository name>-architecture-<date>-<time>`,
   written out in every step. Run every command from inside the
   repository.

2. **Find the product.** `flashteams code_map` with no product lists the
   products; pick the one this repository belongs to (by its repository
   address or name; ask the person when it is not clear). If that product
   has a code map, use it:
   - `flashteams code_map --products <name>` for the map of its parts;
   - `flashteams help query_codebase` first, then `query_codebase` with
     operations such as CYCLES (dependency cycles), HUBS (modules
     everything leans on), ORPHANS (code nothing uses), COMPONENTS (the
     main parts) and IMPACT (what a change to one part reaches);
   - `read_docs` for the product's documentation.

   Check what the map says against the code: the map can be older than
   this checkout.

3. **Read the repository** where there is no map, and to fill the gaps
   where there is one: the manifests (package.json, go.mod, Cargo.toml,
   pyproject.toml and the like), the README and docs, the entry points
   (servers, handlers, jobs, command lines), the folder structure, the
   data access code and schema, and the configuration.

4. **Look for the risks:**
   - dependency cycles between modules or packages;
   - modules everything leans on, which are single points of failure;
   - dead code: parts nothing calls;
   - unclear ownership of auth and of data access, such as permission
     checks spread across handlers, or queries made from many layers;
   - coupling across layers, such as the interface reaching into the
     database, or shared state between parts that should be separate;
   - risky choices that are hard to reverse, such as a data model that
     cannot grow, or one vendor's features built into everything;
   - performance bottlenecks, such as queries in loops, work done on
     every request that could be done once, or one process doing all the
     work.

5. **Write the notes**, `<work folder>/notes.json`, with each risk as an
   added finding:

   ```json
   {
     "add": [
       {"category": "architecture", "severity": "high", "title": "Billing and accounts import each other",
        "path": "src/billing/index.ts", "line": 1, "rule": "architecture.cycle",
        "detail": "What it is and why it matters here.", "recommendation": "How to untangle it."}
     ]
   }
   ```

   Use category `architecture` (or `security` for an auth boundary that is
   already broken), a severity (critical, high, medium, low or info) for
   how much it puts at risk, a rule such as `architecture.cycle`,
   `architecture.hub`, `architecture.dead-code`,
   `architecture.auth-boundary`, `architecture.data-access`,
   `architecture.coupling`, `architecture.hard-to-reverse` or
   `architecture.performance`, and `path` and `line` when the risk has a
   place (leave them out when it does not).

6. **Write the report**, `<work folder>/report.md`, for a new engineer, in
   plain language: what the system is and who uses it, its main parts and
   what each does, how data flows through them (a request from the
   outside to the database and back), where the auth boundaries are and
   who checks what, then the risks with `file:line`, why each matters and
   what to do, and a short fix-first list. Say what you could not see.
   Write a short summary of a few sentences in `<work folder>/summary.md`
   (at most 4,000 characters).

7. **Build the payload.**

   ```sh
   perl "HELPER" payload --out "<work folder>" --kind architecture --summary-file "<work folder>/summary.md" --report-file "<work folder>/report.md" --notes "<work folder>/notes.json"
   ```

8. **Record it in FlashTeams.** `perl "HELPER" send --out "<work folder>"`
   runs `record_code_scan` through the `flashteams` command and prints its
   answer. With only the MCP tools, call `record_code_scan` with the fields
   of `payload.json` as its arguments.
   - Exit 0: the answer has `scan_id`, the counts and a `url`.
   - Exit 1 with `"reason": "repository_not_linked"`: show the person the
     `products` in the answer, ask which one this checkout belongs to, and
     send again with `--product-id <id>` (with MCP, add `product_id`).
   - Exit 1 otherwise: read the reason and tell the person.
   - Exit 3 or 4: tell the person what the message says.
   - Exit 5: it may have been recorded. Do not send it again on your own;
     tell the person.

9. **Tell the person** what the system is in a few lines, the main risks,
   the link, and where the report is. Offer to save a copy of the report
   into the repository; do it only if they want one.

10. **Offer tasks for the high and critical risks, and wait for a yes:**
    `flashteams file_scan_tasks --scan_id <scan id> --min_severity high`,
    or for chosen ones `--fingerprints <fingerprint>` (from
    `payload.json`), once per finding. With MCP, call `file_scan_tasks`
    with the same arguments.
