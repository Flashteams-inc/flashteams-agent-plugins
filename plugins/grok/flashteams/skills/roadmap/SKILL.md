---
name: roadmap
description: Use when the person wants to add a feature to a FlashTeams roadmap or start a roadmap, see what is planned or in flight on the roadmap, tag a design, an analysis, a diagram, a FlashBrain chat, a task or a project to a roadmap feature, mark a feature shipped, or read or leave the lessons on a feature (what failed or worked there). Finds, reads and changes the features on FlashTeams' product Roadmap, each tied to the work, designs, analyses, diagrams and chats about it, and the lessons the chats on it left.
---

# Roadmap

FlashTeams' Roadmap is where an organization plans what it builds. A
roadmap is a named plan with a department, such as "Second half of 2026",
and it holds features. A feature, such as "FlashMate in Slack", is a
planned capability at one stage: Later, Up next, Building now or Shipped.
It is tagged with the products and codebases it touches, shows on each of
those products' Roadmap tabs, and has a page of its own. Tied to it are
the projects and standalone tasks that build it, and the Flash Design
spaces, the analyses and diagrams shared from Flash Console, and the
FlashBrain chats about it. A program's roadmap of projects is another
thing, which the flashteams skill covers.

Managers (owners, executives, admins and project managers) start
roadmaps and add and change features. Builders tag only their own work:
standalone tasks they filed or hold, designs they made or can edit,
analyses and diagrams they shared, and chats they are in.

## The tools

FlashTeams is reached through the `flashteams` command that Flash Console
provides (the flashteams skill says how; `flashteams help <tool>` shows a
tool's arguments). When the command is not here, use the FlashTeams MCP
tools of the same names and arguments. With neither, say so.

- `roadmap_search`: the roadmaps and features whose names hold `q`, or
  all of them with no `q`, with their ids and page links, and each
  feature's stage, roadmap and products.
- `roadmap_feature`: one feature: its stage, dates, roadmap, products and
  progress, and the projects, tasks, designs, analyses, diagrams and chats
  tied to it. What you may not see is counted as private, never named.
- `roadmap_candidates`: what you may tag to a feature, of one `kind`
  (`project`, `task`, `design`, `analysis`, `diagram` or `chat`), whose
  names match `q`, with their ids.
- `roadmap_tag`: `action` `tag` or `untag`, one `kind`, and the `ids`.
- `roadmap_create_feature`: a new feature: its `title`, `description`,
  roadmap (`roadmap_id`) or products (`product_ids`), `stage`, target
  dates and `department_id`.
- `roadmap_update_feature`: a feature's title, description, `stage`
  (`building`, `next`, `later` or `shipped`), target dates, roadmap
  (`roadmap_id`, null takes it out) or products.
- `roadmap_create`: a new roadmap: its `name`, `department_id`,
  `product_ids`, description and owner.
- `roadmap_lessons`: a feature's lessons, what failed, what worked and
  what is good to know: `action` `list` (`feature_id`, or `task_id` for
  the feature a task is part of), `add` (`kind` `failed`, `worked` or
  `tip`, `text`, and `session`) or `remove` (`lesson_id`).

## Features

- To show what is planned or in flight, list it with `roadmap_search` and
  no `q`, then read the features that matter with `roadmap_feature`.
- Find the feature with `roadmap_search` before you act on one. Read it
  with `roadmap_feature` when what it is for matters to the work, such as
  before you plan, design or build for it.
- When it is unclear which feature the person means, or several match,
  ask. Never guess.
- Add a feature or start a roadmap only when the person asks for one, and
  search first so you never add one twice. Pick the roadmap and products
  from what they said: a feature in a roadmap starts with the roadmap's
  products and department, and `code_map` with no products lists the
  products and codebases you can see, with their ids. When the roadmap or
  the products are unclear, ask once. Leave `stage` out unless they name
  one: a new feature starts Up next.
- Change a feature only as the person asks. Mark it shipped only when
  they say it is done or live; otherwise leave its stage to them.
- Then say what you did in a line, with the feature's page link.

## Tagging

- **A Flash Design space:** right after `design_create`, when the design
  is for a feature's work, tag it (`kind` `design`, the space's id).
- **An analysis or a diagram:** once it is shared to FlashTeams. Find its
  share id with `roadmap_candidates` (`kind` `analysis` or `diagram`, `q`
  its title); the id of its record in Flash Console's Library is not a
  share id.
- **A FlashBrain chat, a standalone task or a project:** when the person
  says it is part of the feature. A task inside a project is tagged
  through its project.
- **A task you make:** `track_work` and `create_task` check the roadmap
  themselves, and the `roadmap` line in their answer says what they
  found. When the match is clear they link a standalone task to its
  feature, and the task then becomes visible to the team instead of
  personal. They say when a task is part of a feature through its
  project. Otherwise they list the features it might be part of
  (`roadmap_features`, with their ids): confirm one with the person, then
  tag it with `roadmap_tag`, a standalone task as `kind` `task` and a
  task inside a project through its project. Never tag a feature the
  person has not confirmed.
- **One task per feature, or per roadmap:** `track_work --action status`
  says how the person tracks roadmap work, in `roadmap_tasks`, with a
  line on what it means. With `per_feature`, the default (and when status
  says nothing about it), each feature gets its own task, so its progress
  counts its own work: when the work moves on to another feature, start
  another task for it with `track_work`, named for that feature, and never
  tag one task to several features. Tagging a task that is already on
  another feature still works, since a manager may mean it, but the
  answer carries a note: tell the person, and make a task for this feature
  instead unless they want it on both. With `per_roadmap`, one task covers
  their work on a roadmap: `track_work --action start` may answer with
  their open task for that roadmap instead of making one (`task_made`
  false). Tag that task to the feature with `roadmap_tag` (`kind` `task`)
  and keep working in it, and pass `--new_task true` only when the person
  wants a new task. The person changes this by asking you to; only then
  call `track_work --action set_preference --roadmap_tasks per_feature`
  (or `per_roadmap`).
- Take a tag off (`untag`) only when the person asks.

An analysis or a diagram stays in Flash Console's Library on the person's
computer until it is shared. Save it there first: an analysis is saved
when you answer with `analysis__answer`, or with `analysis__save`, and a
diagram with `diagram__save_diagram` (Flash Console's own tools; in Claude
Code, `mcp__flash-console__analysis__save` and so on). No tool shares one
for you, so ask the person to share it from Flash Console: an analysis
with Share beside its title on its Analysis tab, or either one with Share
in its menu in the Library, where they choose who can open it. Then find
it with `roadmap_candidates`. A share keeps its id as new versions are
saved, so tag it once.

## Lessons

Each chat on a feature leaves what it learned there, so the next chat on
it, anyone's, starts from it.

- `load_task` and `track_work --action start` bring the lessons of the
  feature a task is part of, in `lessons`. Read them before you plan, and
  never repeat what they say did not work.
- As you go, when something fails or works that the next chat should
  know, record it with `roadmap_lessons --action add` (`--kind failed`,
  `worked` or `tip`, `--text` in plain words, `--task_id`, `--session`).
  Or pass up to five as `--lessons` when you finish with `update_task`
  (`submit_for_review` or `close`) or `track_work --action finish`, such
  as `--lessons '[{"kind":"failed","text":"..."}]'`. When a task is part
  of several features, the answer names them: ask the person which.
- `track_work --action status` says in `lessons_reach` how far the
  person's agents read: `feature`, `roadmap` (the default) or
  `codebase`. Set it only when the person asks, with `track_work --action
  set_preference --lessons_reach <choice>`.
- Remove a lesson only when the person asks.

## When it says no

Say why in a line, plainly, and do not repeat the call unchanged.

- A Builder adding or changing a feature, or starting a roadmap: say that
  is for managers, and that they can still tag their own work to it.
- "You can tag only ..." or not found: it is not theirs to tag, or they
  cannot see it.
- An archived feature takes no tags until someone restores it.
