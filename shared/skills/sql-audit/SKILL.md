---
name: sql-audit
description: Use when the person asks for a SQL audit or a database security review of this repository, such as SQL or NoSQL injection in the code, risky grants, tables without row-level security, security definer functions, personal data stored as plain text, dynamic SQL in stored procedures, or database passwords in the code. Runs FlashTeams' SQL rules on this computer, adds its own review of migrations and schema files, and records the results in FlashTeams.
---

# SQL audit

Check this repository's SQL and the code that builds it: FlashTeams' rules
find injection and risky statements, and you review what rules cannot
judge. Then write a report and record it in FlashTeams. This is a laptop
scan: it shows beside the scan FlashTeams runs, and never replaces it.

Rules for the whole audit:

- **Never print or repeat a secret's value**, such as a database
  password: not in a message, the report, the notes or a command. The
  helper's `show` prints `[hidden]` in its place. Do not open a secret's
  line with any other tool (cat, grep, sed or your file reader). Say where
  it is and what kind it is, never what it is.
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

In Codex, `install`, `rules` and `send` need the network or Flash
Console's socket: run them outside the sandbox when Codex asks.

## Steps

1. **Agree what to check.** Unless the person already said, ask which
   folder (the whole repository by default). Pick the work folder once:
   run `echo "${TMPDIR:-/tmp}"` and use
   `<that>/flashteams-scan/<repository name>-sql-<date>-<time>`, written
   out in every step. Run every command from inside the repository.

2. **Check the scanners.** `perl "HELPER" doctor`. The SQL audit uses
   opengrep (semgrep stands in when it is missing) and gitleaks.

3. **Offer to install what is missing, and wait for a yes.** Tell the
   person the choices `doctor` printed (`perl "HELPER" install <tool>...`,
   which downloads the version FlashTeams uses and checks it against a
   pinned checksum, or Homebrew on a Mac). Run only what they agree to. If
   they say no, carry on: the scan records each missing scanner.

4. **Get FlashTeams' rules.** `perl "HELPER" rules` asks FlashTeams for
   them (`get_scan_rules`, which only reads) and prints the rules folder
   on its last line. With only the MCP tools: call `get_scan_rules`, then
   `perl "HELPER" rules --url '<url>' --sha256 <sha256>`. Without rules
   the SQL rules cannot run, and your own review (step 7) carries the
   audit.

5. **Run the scan.**

   ```sh
   perl "HELPER" run --kind sql --path <folder> --rules "<rules folder>" --out "<work folder>"
   ```

   It runs FlashTeams' rules for `.sql` files and the rules for SQL and
   NoSQL injection in application code, and gitleaks on `.sql` files.
   Leave `--path` out for the whole repository. Give it a long timeout on
   a large repository.

6. **Judge the findings.** Read the summary, then
   `perl "HELPER" show --out "<work folder>" --ids 1,2,5` for every
   critical and high finding and anything doubtful, and open the code to
   see where the values come from.

7. **Review what the rules cannot judge.** Find the migrations and schema
   files (`git ls-files '*.sql'`, folders such as `migrations` or
   `schema`, ORM models and schema files) and the code that builds
   queries, and look for:
   - tables without row-level security when the database uses it for
     others (for example a Postgres table with no
     `ENABLE ROW LEVEL SECURITY` beside tables that have it), and
     policies that let everyone through;
   - grants to everyone or to anonymous roles (`TO PUBLIC`, `anon`, a role
     every signed-in user has) wider than they need;
   - `SECURITY DEFINER` functions without a fixed `search_path`;
   - columns holding personal data, such as national id numbers, card
     numbers, bank account numbers or dates of birth, stored as plain
     text;
   - stored procedures and dynamic SQL: `EXEC`, `EXECUTE` or
     `sp_executesql` with text built by joining strings;
   - database passwords written in migrations, settings or connection
     strings.

8. **Write the notes**, `<work folder>/notes.json`:

   ```json
   {
     "dismiss": [4],
     "notes": {"2": {"detail": "Why it matters here.", "recommendation": "How to fix it here."}},
     "add": [
       {"category": "sql", "severity": "high", "title": "orders has no row-level security",
        "path": "supabase/migrations/20260101_orders.sql", "line": 3, "rule": "agent.sql.no-row-level-security",
        "detail": "...", "recommendation": "..."}
     ]
   }
   ```

   `dismiss` takes false positives out (say why in the report), `notes`
   replaces a finding's detail and recommendation with yours, and `add`
   records each problem from your own review with category `sql` and a
   severity (critical, high, medium, low or info). Numbers are the
   finding numbers from the summary.

9. **Write the report**, `<work folder>/report.md`, in plain language:
   what was checked (folder, branch, commit, whether there were changes
   not committed, rules version), which tools ran and which did not, the
   counts, the findings that matter with `file:line`, why each matters
   and how to fix it, a remediation list ordered by risk, what was
   dismissed and why, and what this audit cannot see (the live database
   itself, as only the repository's files are read; data already stored;
   the git history). Write a short summary of a few sentences in
   `<work folder>/summary.md` (at most 4,000 characters).

10. **Build the payload.**

    ```sh
    perl "HELPER" payload --out "<work folder>" --kind sql --summary-file "<work folder>/summary.md" --report-file "<work folder>/report.md" --notes "<work folder>/notes.json"
    ```

11. **Record it in FlashTeams.** `perl "HELPER" send --out "<work folder>"`
    runs `record_code_scan` through the `flashteams` command and prints
    its answer. With only the MCP tools, call `record_code_scan` with the
    fields of `payload.json` as its arguments.
    - Exit 0: the answer has `scan_id`, the counts, `new_since_last`,
      `fixed_since_last` and a `url`.
    - Exit 1 with `"reason": "repository_not_linked"`: show the person the
      `products` in the answer, ask which one this checkout belongs to,
      and send again with `--product-id <id>` (with MCP, add
      `product_id`).
    - Exit 1 otherwise: read the reason and tell the person.
    - Exit 3 or 4: tell the person what the message says.
    - Exit 5: the scan may have been recorded. Do not send it again on
      your own; tell the person.

12. **Tell the person** the counts, what is new and what was fixed since
    the last scan, the link, and where the report is. Offer to save a copy
    of the report into the repository; do it only if they want one.

13. **Offer next steps, and wait for a yes for each.**
    - Tasks for the critical and high findings, assigned to the person:
      `flashteams file_scan_tasks --scan_id <scan id> --min_severity high`,
      or for chosen findings `--fingerprints <fingerprint>` (from `show`
      or `findings.json`), once per finding. With MCP, call
      `file_scan_tasks` with the same arguments.
    - Fixing them, in the order of the remediation list. Change code only
      after they agree, and do not commit.
