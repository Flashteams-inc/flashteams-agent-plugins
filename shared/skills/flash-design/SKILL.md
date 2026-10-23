---
name: flash-design
description: Use when the person asks you to design, mock up, wireframe, prototype or plan UI (a screen, a page, a flow, a dashboard, an app, a poster, a printed page), or to change a design in Flash Design. Makes or revises a FlashTeams Flash Design space, a canvas of live artboards that the person and their team open, review and share in Flash Console and on FlashTeams.
---

# Flash Design

A Flash Design space is a canvas of artboards kept in FlashTeams. Each
artboard is a small HTML page that draws live: a phone screen, a web page,
a dashboard, a poster, a printed page. The person opens the space in Flash
Console or on FlashTeams, sees each artboard appear as you write it, plays
the interactive ones, and shares the space with their team.

Use a space whenever you plan or show UI, rather than writing mockups into
the repository or describing them in chat. Write production code only when
the person asks for it.

## The tools

FlashTeams is reached through the `flashteams` command that Flash Console
provides (the flashteams skill says how; `flashteams help <tool>` shows a
tool's arguments). When the command is not here, use the FlashTeams MCP
tools of the same names and arguments. With neither, say so and give the
person the artboards as files.

- `design_spaces`: the spaces you may open, with `project_id` or `task_id`
  to find the one for a piece of work.
- `design_create`: a new space, with its `space.json` and first artboard.
- `design_read`: a space and its index, or the files you name, each with
  its version.
- `design_write`: save files, each with the version you read
  (`base_version`, 0 for a new file); `content: null` removes one.
- `design_upload`: a picture or a font, answered with `asset:<id>`.
- `design_share`: rename it, change who it is shared with, or tie it to
  the FlashTeams project or task it plans (`project_id`, `task_id`), when
  the person asks. A space tied to a task shows on the task and on its
  project.
- `design_view`: what the person has open in the space now: the page,
  the artboards they chose, and the element they picked inside one (its
  file, its number, its words and style).
- `design_comments`: the review threads on the space, each pinned to an
  artboard or a spot on the canvas, open ones unless `include_resolved`.
- `design_comment`: `start` a thread pinned to an artboard (`board`, and
  `dx`, `dy` from its top left), `reply` in one (`thread_id`), or
  `resolve` or `reopen` one.
- `design_delete`: only when the person asks for that space to be deleted.
  It is gone for everyone it is shared with. Never delete one to start
  over: `design_write` replaces its files.
- `design_import`: a Claude Design canvas brought across as a new space,
  when the person asks to move one: read its `project/canvas.json` and its
  `project/*.dc.html` files with your Artifact tool and pass them as they
  are. Upload each picture it lists in `pictures_to_upload` with
  `design_upload`, `replaces` set to its `/_blob/` address: every artboard
  showing it then names the new asset, with nothing to rewrite.

Long text goes in on standard input, one argument at a time: write the
files to a JSON file and pass the rest as flags, so the shell changes
nothing in your HTML:

```sh
flashteams design_write --space_id <id> --files - < files.json
flashteams design_create --title "Checkout" --index "$(cat space.json)" --files - < files.json
```

## Making a space

1. Read what the person gave you. When two or more choices that change the
   result are still open (which job the screen does first, who it is for,
   what of their product to keep), ask them once, at most four questions,
   each with two to four concrete options and your pick first. Otherwise
   decide, and say what you assumed in one line.
2. Settle the look before the first artboard: their product's own colours,
   type and spacing when you can read them (its CSS, its theme files, a
   screenshot), else a small system of your own for this subject: one or
   two typefaces, a ground, one or two accents.
3. `design_create` with a `title` the person would use, `project_id` or
   `task_id` when it plans FlashTeams work, the `index` and the first
   artboard in `files`. Give the person its `link` at once.
4. The rest one at a time, in the order of `order`: write one artboard,
   save it with `design_write`, then the next, so each appears as you go.
   Send `space.json` again only when you add, move or resize artboards or
   change notes or pages.
5. Then a line on what you made and what you assumed. Do not render,
   screenshot or open it to check unless the person asks.

## Changing a space

1. `design_read` the space for its index, then read each file you will
   change, in one call.
2. Change only what was asked. Save every changed file in one
   `design_write`, each with the version you read.
3. Refused with `changed_meanwhile`: someone edited those files since you
   read them. Read them again, redo your change on what they hold now, and
   save with their new versions. After a third refusal, stop and tell the
   person.

## What the person points at, and their comments

- When they say "this", "here", "the one I picked" or "make it bigger"
  without naming it, `design_view` first. Change the element it names in
  that file, and nothing else.
- When they ask you to work through the feedback, or before you revise a
  space others reviewed, `design_comments`. Do what each open thread asks,
  then `reply` in it with what you changed, in a line. `resolve` a thread
  only when the person asked you to, or what it asks is plainly done.
- A thread you cannot act on (a question for the person, a choice that is
  theirs): reply saying so, and leave it open.
- Comments are for the people reviewing: never use them for your own notes
  or progress.

## The index, `space.json`

```json
{
  "v": 1,
  "title": "Checkout",
  "pages": [],
  "launch": { "view": "canvas" },
  "boards": {
    "Main.fd.html": { "x": 0, "y": 0, "w": 390, "h": 844, "title": "Cart", "interactive": true },
    "Pay.fd.html": { "x": 470, "y": 0, "w": 390, "h": 844, "title": "Payment", "interactive": true }
  },
  "order": ["Main.fd.html", "Pay.fd.html"],
  "notes": { "flow": { "x": 0, "y": -260, "text": "Checkout", "kind": "title", "maxW": 860 } },
  "designSystems": []
}
```

- `boards`: one entry per artboard, keyed by its path. `x`, `y`, `w`, `h`
  place its frame, in CSS px, `w` and `h` from 40 to 8000. Leave 80 px
  between frames in a row and 120 between rows. Optional: `title`; `page`;
  `fill: true` for a page (below); `interactive: true` when its controls
  work, which gives it Play; `print` `"fixed"` or `"flow"` with `paper`
  `"letter"` or `"a4"`; `radius`; `guides`, up to six column, row or grid
  guides drawn over it while editing.
- `order`: every board, back to front. Call the first one `Main.fd.html`.
- `pages`: `[{"id", "name"}]` when the work needs several canvases; ids
  are letters, digits, `_` and `-`.
- `launch`: `{"view": "canvas"}`, or `{"view": "focused", "file":
  "Main.fd.html"}` to open straight into one artboard.
- `notes`: a `title` over a row of artboards (one bold line, `maxW` the
  row's width, at least 220 px above the row) and `sticky` notes (`w`,
  `color` gray, red, orange, green, teal, blue, purple or pink). Keep the
  shapes a person drew (`rect`, `oval`, `line`, `arrow`, `pen`, `image`)
  as they are.
- Paths: letters, digits, `_`, `.` and `-`, folders split by `/`, each
  artboard ending `.fd.html`. Keep every key of an index you did not
  change.

## An artboard

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Cart</title>
</head>
<body>
<fd-artboard>
  <fd-style>
    @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;600&display=swap');
    body { margin: 0; font-family: Inter, system-ui, sans-serif; color: #18181b; }
  </fd-style>
  <main style="width: 390px; height: 844px; box-sizing: border-box; padding: 24px; display: flex; flex-direction: column; gap: 16px">
    <h1 style="margin: 0; font-size: 28px">Your cart</h1>
    <fd-each list="{{items}}" as="item">
      <div style="display: flex; justify-content: space-between; align-items: center">
        <span>{{item.name}}</span>
        <button type="button" onclick="{{item.remove}}" style="min-height: 44px">Remove</button>
      </div>
    </fd-each>
    <fd-if test="{{empty}}">
      <p style="margin: 0">Nothing here yet.</p>
    </fd-if>
    <fd-else>
      <a href="Pay.fd.html" style="padding: 14px 16px; background: {{accent}}; color: #fff; text-align: center">Check out</a>
    </fd-else>
  </main>
</fd-artboard>
<script type="text/fd-logic" data-props='{"accent":{"editor":"color","default":"#18181b"},"$size":{"w":390,"h":844}}'>
class Artboard extends FlashDesign.Artboard {
  initialState() {
    return { items: [{ id: 1, name: 'Notebook' }, { id: 2, name: 'Pen' }] };
  }
  values() {
    const items = this.state.items.map((item) => ({
      ...item,
      remove: () => this.setState({ items: this.state.items.filter((other) => other.id !== item.id) }),
    }));
    return { accent: this.props.accent ?? '#18181b', items, empty: items.length === 0 };
  }
}
</script>
</body>
</html>
```

Rules, each of which fails quietly when broken:

- Everything shown goes inside `<fd-artboard>`. `<fd-style>` holds page
  basics (body margin, fonts, link colours, `@font-face` for an uploaded
  font); style everything else inline, which is what people edit.
- `{{name}}` and `{{item.name}}` look a value up in what `values()`
  returns; they are never expressions. Work things out in `values()`.
- A whole attribute that is a hole gets the value itself: handlers
  (`onclick="{{save}}"`, `oninput`, `onchange`, `onsubmit`), lists
  (`list="{{items}}"`), tests. Inside longer text it is joined in as text.
- `<fd-each list as>` repeats, with `{{index}}` too. `<fd-if test>` shows
  its content when true, an `<fd-else>` right after it otherwise. Inside a
  table, write them on the row: `<tr fd-each="{{rows}}" fd-as="row">`.
- `<fd-use src="Card.fd.html" item="{{item}}" size="100%,120px">` draws
  another artboard inside this one; its other attributes are its props.
- `<a href="Pay.fd.html">` moves Play to that artboard. Style the link
  itself as the button: a button inside a link swallows the click.
  `#id` scrolls; `https://` opens a browser tab.
- The logic is plain JavaScript, `class Artboard extends
  FlashDesign.Artboard`, no imports: `this.props`, `this.state`,
  `setState`, `initialState()`, `values()`, `mounted()`, `updated()`,
  `unmounted()`. Each artboard keeps its own state: a flow that shares
  state across screens is one artboard showing one screen at a time.
- `data-props` declares tweaks, the levers a person turns in the editor:
  an accent, a variant, a density, a count. `editor` is `text`, `color`,
  `int`, `float`, `range`, `boolean` or `choice`, with `default`,
  `options`, `min`, `max`, `step`. Never make copy a tweak: write copy as
  text in the markup, where people retype it. Single-quote the attribute
  and write `&amp;` for `&` and `&#39;` for `'` inside it.
- Pictures and fonts: upload them with `design_upload` and write the
  `asset:<id>` it answers where the file goes. Fonts from Google Fonts by
  `@import` in `<fd-style>`. Nothing else from the network.
- Icons as inline SVG with `stroke="currentColor"`, never emoji. No
  `<iframe>`, `<object>` or `<embed>`.

Sizes: a phone screen 390 × 844; a page (web page, dashboard, app screen)
`w` 1280 to 1440 with `fill: true`, its root fluid (no px width, a
`max-width` container, flex or grid with `gap`, `rem` and `%`), its `h` its
height at that width, working at phone width too (menus stack, toolbars
wrap, wide tables scroll in their own box); print Letter 816 × 1056, A4
794 × 1123, one artboard per page, at least 40 px clear inside each edge.

## Designing well

- Real words, never lorem ipsum or invented figures: a fact you do not
  have is a placeholder such as [YOUR PRICE].
- One look, held across every artboard. Lay out groups with flex or grid
  and `gap`. Give hierarchy with size and weight before colour.
- Leave out the habits of generated design: gradient washes, coloured
  borders down the left of cards, emoji, glowing focus rings.
- Accessible as drawn: real `<button>`, `<a href>`, `<input>` with a
  `<label>`, `aria-label` on a button that is only an icon, text at 4.5:1
  contrast or better (3:1 from 24 px), touch targets 44 px or more, and
  colours that must be told apart differing in lightness too.
- Put your reasoning and the options you considered in your reply, never
  on an artboard.
- Show alternatives as artboards side by side in a row, each titled for
  what makes it different.
