# Taskboard

A personal kanban in the macOS menu bar: dictate with a hotkey, and Claude (the wingform profile) sorts what
you said into tasks. The list shows as a translucent widget in the top-right corner.

| Hotkey | What it does |
|---|---|
| `⌃⌥⌘R` | start / finish a voice note |
| `Esc` | cancel a recording (only while it runs) |
| `⌃⌥⌘K` | open the board |
| `⌃⌥⌘W` | hide / show the widget (or ✕ on hover) |

Note → on-Mac transcription (Speech) → `claude -p` with `CLAUDE_CONFIG_DIR=~/.claude-wingform`, which only
has the `taskboard` tools → tasks on the board. If Claude is unavailable or changed nothing, the note still
lands on the board as a task, as is.

Taskboard is a regular macOS app: a Dock icon, Cmd-Tab, a menu bar (Taskboard, Actions, Edit, Window) and the board
window, which opens at launch and again on a click on the Dock icon; closing the window leaves the widget, the menu bar
item and the hotkeys running. The widget stays as it was. In the menu bar item or the app menu:
- **Show in Dock** — off turns it into a menu-bar-only app (no Dock icon, not in Cmd-Tab) right away;
- **Open board at launch** — off starts it quietly with just the widget (say, after launch at login).

A hidden widget shows itself during recording and processing, then hides again.
Widget: "Doing", then "To do", up to 10 rows; the circle marks a task done, the header opens the board.
It is hidden from screen recording and sharing (`defaults write com.lozhka13.taskboard widgetCapturable -bool true` shows it).
Board: drag between columns, double-click to edit, right-click for priority and delete.
"Done" older than a week moves to `archive.jsonl`.

## Language

Interface, messages and everything Claude writes are in English. Dictation is recognized as `en-US` by
default; for another language set `transcriptionLocale`, e.g.
`defaults write com.lozhka13.taskboard transcriptionLocale ru-RU`. Claude understands notes in either
language and answers in English.

## Projects, journal, documents

Tasks are grouped by project. In the board window: a strip of project tabs on top (All, one per project,
No project — each with its open-task count; `+` — new project) and the tabs **Board / Journal / Documents**
below it (sliders — project settings). **Drag a task card onto a project tab** to move it there (with its
subtasks); drop it on "No project" to clear the project. A move is noted in the journals of both projects.

- **Journal** — a Markdown file per project (`projects/<slug>/log.md`); the general one is `log.md` in the
  data folder. Task changes (new, moved between columns, deleted) are written automatically wherever they
  come from: widget, board, voice or Claude. The rest (meeting outcomes, decisions, deadlines) is written by
  Claude through `log_entry`, or by you in the Journal tab.
- **Documents and notes**: drop a file on the widget or the board window, press "File" / "Note". The file is
  copied to `projects/<slug>/docs/` (without a project — to `inbox/`), Claude reads the text (txt, md, pdf,
  rtf, docx), logs the gist, creates tasks from explicit next steps (at most seven), and, with no project
  given, picks one by content or leaves the document in the inbox. The project is decided per task: one that
  fits no existing project is still created, under "No project" — never dropped, never forced into the wrong
  project. If Claude is unavailable the file is
  still saved and noted in the journal.
- Claude sees documents as **data**, not instructions, and has only the `taskboard` tools.
- A project must exist: MCP rejects an unknown name and lists the known ones; a new one is created only
  explicitly (`create_project`).

MCP tools: `list_projects`, `create_project`, `update_project`, `log_entry`, `read_log`,
`list_documents`, `read_document`, `file_document`.

## Email check (Gmail, read-only)

Claude looks through the last few days of the inbox and does three things: writes **journal entries** (with a
link to the thread) for decisions, deadlines and commitments that belong to a project; **proposes tasks**
when you are explicitly asked to do something or committed to something; and **proposes status changes** when
a thread shows a task started or finished. Proposals wait in a queue — in the widget (✓ / ✕, up to three) and
in the board's **Proposals** tab (Accept / Reject / Accept all) — and nothing becomes a task until you accept.
A rejected proposal is remembered and never comes back.

- **Read-only by construction.** The run has no built-in tools, Gmail is limited to search / read (every
  other Gmail tool is denied by name), the taskboard server runs in `sync` mode where it only exposes read
  tools, the journal and the proposals queue — it cannot create, change or delete tasks — and anything
  not on the allow-list is refused without asking. Email content is treated as data, never as instructions.
- **When it runs.** `Email` button in the board toolbar or "Check email now" in the menu. The first run is
  always manual; after one has succeeded it repeats by itself every 60 minutes while the app is open.
- **Connector flakiness.** The Gmail connector comes from the account and shows up in only some `claude -p`
  runs (about one in four in testing, no matter how long a run waits). A run without it ends in seconds, says
  `GMAIL_UNAVAILABLE` instead of pretending the inbox is empty, and is started again — up to 8 tries.
- **Report.** The email check also ends with a report (sender, subject and outcome per thread, plus a
  "Not covered" line); the clipboard button next to the "checked …" time opens it.
- **Not read twice.** Looked-at threads are remembered in `sync-state.json` with the date of their latest
  message; a thread is read again only when something newer arrives.
- **What it skips.** Newsletters, receipts, alerts and other automated mail: Gmail filters the obvious senders
  (`noreply`, `notifications`, anything with "unsubscribe") and Claude skips the rest.
- Settings (`defaults write com.lozhka13.taskboard …`): `emailDays` (3), `emailSyncMinutes` (60, `0` turns
  automatic runs off), `emailQuery` (the Gmail search; default `in:inbox newer_than:3d -from:(noreply OR …)`).
- The Gmail connector comes from the Claude account logged in to the `wingform` profile (claude.ai →
  Connectors), so the mailbox is that account's. Email content is processed by Claude like documents are.

## Slack check (read-only)

The same pattern as the email check, for one Slack workspace — the one the `claude.ai Slack` connector of the
`wingform` profile is connected to. Claude reads **the channels you map to projects** (public or private),
**messages that mention you**, **threads you take part in** and **your direct messages**, then writes journal
entries (with the message permalink), proposes tasks when you are asked or have committed to something, and
proposes status changes. Proposals land in the same queue (widget, **Proposals** tab) and nothing becomes a
task until you accept.

- **Map channels:** project settings (sliders) → "Slack channels", e.g. `#jssi, #deals` (a channel id such as
  `C0123ABCD` also works). Without a mapping only mentions, threads and DMs are read.
- **Read-only by construction.** Only search/read tools are allowed (search, read channel, read thread, user
  profile, search users and channels, your channel list); the other 19 Slack tools — posting, drafts, reactions,
  canvases, lists, uploads, file and canvas reading — are denied by name, tasks can't be changed by the run, and
  Slack content is data, never instructions.
- **DMs and private channels hold other people's personal matters.** The run is told to write down only the
  work substance (a request, a commitment, a decision, a deadline) and never copy personal, HR, salary or
  health details into a journal entry or a proposal. Everything it reads is processed by Claude.
- **When it runs:** `Slack` button in the board toolbar or "Check Slack now" in the menu; the first run is manual,
  then every 60 minutes while the app is open. Only what is newer than the last run is read
  (`sync-state.json`). Like Gmail, the connector shows up in only some `claude -p` runs, so a run that doesn't
  see it says `SLACK_UNAVAILABLE` and is retried (up to 8 times).
- **Report.** Every check ends with a report of what it looked at — one line per conversation or thread
  (name, number of new messages, what it did with it) plus a "Not found / Not covered" line for anything it
  expected but couldn't read — never message text. The clipboard button next to the "checked …" time opens it,
  so a gap in coverage is visible. It is kept in `sync-state.json` until the next successful check.
- Settings: `slackDays` (3), `slackSyncMinutes` (60, `0` turns automatic runs off).
- One workspace only for now; several workspaces are not supported yet.

## Everything task-like goes to Proposals — yours and other people's

The email, Slack and document checks propose **anything that reads like a task** — a request, an action item, an
agreement, a commitment, a deadline — **whoever is to do it**, not just you: you see other people's tasks too, to
remember them. Each proposal carries an **owner** (a name as in the source, "me" for you, empty when unclear), shown
as "— Maria" in the list and as an orange "for Maria" in the Proposals tab; an accepted task keeps it (an owner chip
on the card, a field in the task window). Tentative ideas are included and marked "tentative" in the reason; small
talk and things already done are skipped. Up to 15 proposals per run; ones that already exist as open tasks, are
waiting, or were rejected are not proposed again.

**Documents work the same way.** A dropped file or pasted note no longer creates tasks on its own: the run has no
tools to create, change or delete tasks (only to propose, log, add updates and file the document), so everything
task-like — and a "this is done" — becomes a proposal. Your own dictation is different: you said it, so it goes
straight to the board.

## Updates on a task

Every task has a timeline of news: what an email, a Slack message, a document, a voice note or you said about it.
The card shows the latest one (with "+N earlier"); the task window (double-click) shows all of them, newest first,
each with a link to its source, a remove button, and a field to add your own.

- **Where news comes from.** The email, Slack and document checks and voice notes call `add_task_update` for
  news about one particular existing task — a deadline moved, a reply, a blocker, a decision, progress. It is
  applied at once (it is a note, not a decision) and journaled in the project with the task number and the
  source link. What concerns the project as a whole still goes to the project journal (`log_entry`).
- **No repeats.** The same news isn't added twice; the newest 100 per task are kept. The task's own "updated"
  time isn't touched, so a Done task doesn't live longer because mail arrived about it.
- Existing journal entries aren't moved onto tasks: they were written without a task number.

## Noticing proposals

The number of proposals waiting is shown as a badge on the Dock icon and next to the menu bar icon (and as the
widget's "Proposals · N" header and the board's **Proposals (N)** tab). A check reports what it did with every
conversation: the clipboard button next to "checked …" — useful when a proposal you expected didn't come.

## Links on tasks: pull requests and artifacts

A task can carry links — pull requests, Claude artifacts, commits, documents, any web page. They show as chips on
the card (click opens them); the task window lists them with a remove button. Every link added or changing state is
noted in the project journal.

**The source of a task or an update is one click away.** A task created from an accepted proposal gets its source as a
chip — an envelope with the email's subject, a "#" with the Slack message — and the journal line "+ #12 …" carries
the same address. The "latest update" line on a card has an arrow that opens the email or message that update came
from (every update in the task window has a "source" link too). Tasks accepted before this existed had their source as
text in the notes ("From email: …" and the address on the next line); those turn into chips when the board loads, and
the address is removed from the notes. Claude can attach such links itself (`attach_link` with kind `email` or `slack`).

**Emails open in the Mail app.** Clicking an email chip, an update's arrow or a proposal's subject opens that message in
Mail instead of the browser. Mail's `message://` links need the message's RFC 822 Message-ID, which the Gmail
connector returns only inside the full raw message (tens of KB, too big to fetch per email), so Claude passes the
subject, sender and date it has already read (`mail_subject`, `mail_from`, `mail_date`) and the app finds the message in
Mail through its scripting — subject, sender, and a day-and-a-half window around the date, in the inbox and "All
Mail" of every account — reads its Message-ID from Mail and opens it. The values go to the script as arguments, never
spliced into its text. If Mail can't be asked or doesn't have the message (the Gmail account isn't in Mail, no
permission, not found in 25 seconds), the Gmail web link opens instead; a right-click on the link always offers
"Open in Gmail (web)". The first click makes macOS ask whether Taskboard may control Mail: Allow. Switch it off with
**Open emails in Mail** in the menu (`defaults write com.lozhka13.taskboard openEmailInMail -bool false`). Emails
linked before this existed are found by their subject alone, which is slower and may pick a similar message.

**Adding a link yourself**, three ways:
- in the task window (double-click the card): paste the address into "Paste a link", optionally give it a title, Enter;
- right-click a card: **Add link…** (the clipboard's link is prefilled), or **Paste link: …** when the clipboard
  already holds one — a single click;
- drag a link from the browser onto a card.

A GitHub pull request or commit and a Claude artifact are recognised as such (a pull request keeps its repo and
number, so the GitHub check keeps its state current while it is in the checked window); anything else is a plain link,
named after its host and the last part of the path unless you give a title. Only http(s) addresses are accepted;
the same link isn't added twice.

- **GitHub check** (`GitHub` button / "Check GitHub now"; the first run is manual, then every 60 minutes).
  1. It asks GitHub (`gh`, read-only) for pull requests into `test` of `JetSetBackend` and `monorepo` (all the
     frontend apps) updated in the last 7 days, without bots, the automatic `sync: …` ones and the
     `merge/dev-to-test-…` promotions.
  2. **No Claude here:** every link already on a task takes the PR's current state — open, merged, **live on
     test**. "Live" means the merge commit is part of the commit the stand reports on `/api/version/`
     (GitHub's compare API); if the stand doesn't answer, what was known stays. Only the backend has such an
     address: the frontend apps report no commit, so their PRs show open / merged but no "live".
  3. Pull requests not linked to any task and not seen before go to Claude, which matches them **by meaning**
     with your open tasks and **proposes**: attach this PR to task #N, optionally moving it (doing for an open PR,
     done only when a merged PR clearly completes the task). Nothing is attached until you accept; a rejected
     match isn't proposed again. It can't change tasks itself.
  The clipboard button next to "checked …" shows what it looked at, PR by PR.
- **Artifacts, from the session itself.** Claude, in a session where the taskboard MCP and skill are installed,
  attaches an artifact it just published to the task it belongs to (`attach_link`) — only when it's clear which
  task; otherwise it asks. The `wingform` profile has both. For another profile (e.g. your everyday one):
  `CLAUDE_PROFILE_DIR=~/.claude ./install.sh`.
- Settings (`defaults write com.lozhka13.taskboard …`): `githubRepos` ("owner/name, owner/name", default
  `JetSetProjects/JetSetBackend, JetSetProjects/monorepo`), `githubBase` (`test`), `githubVersionURLs`
  ("owner/name=https://…/api/version/, …"), `githubDays` (7), `githubSyncMinutes` (60, `0` — no automatic runs).

## Install

```bash
./install.sh   # builds, installs to /Applications, connects the taskboard MCP to ~/.claude-wingform
```

On the first recording macOS asks for microphone and speech-recognition access. Launch at login is in the menu.

**Permission prompts after every reinstall** (Downloads, Desktop, Music, microphone…): the app is signed ad hoc,
and an ad hoc signature changes with every build, so macOS forgets what was allowed. Run
`./scripts/make-signing-identity.sh` once (it creates a self-signed certificate "Taskboard Local" in your login
keychain and asks you to authorize trusting it for code signing); from then on `install.sh` signs with it, the
app keeps one identity, and the prompts come once. The checks also start their `claude` and `gh` processes from the
data folder, not from `/`.

## Claude

The `taskboard-mcp` MCP server lives in the bundle and is connected only to the wingform profile, together
with the `skills/taskboard` skill (a symlink in `~/.claude-wingform/skills`). In a regular `wingform` session
you can say "put this on the board…", "break this into tasks…", "what can I take?" or "mark #12 done".

Tasks form a tree (`parent` — a subtask) and depend on each other (`depends_on` — can't start until those
are done). Tools: `list_tasks` (tree, or `view: ready` — what can be taken), `get_task`, `add_task`,
`add_plan` (branching work at once, atomic, with cycle checks), `update_task`, `move_task` (reports what got
unblocked), `delete_task`. How to lay work out is in `skills/taskboard/SKILL.md`.

The widget shows what can be done: doing, then available, then blocked (with a lock); groups with open
subtasks aren't duplicated in it — their title is shown under the subtasks.

## Data

`~/Library/Application Support/Taskboard/`: `board.json` (the board and the project registry, written under
flock by the app and MCP), `archive.jsonl`, `voice/*.txt` (transcripts), `log.md` (general journal),
`inbox/`, `projects/<slug>/{log.md,docs/}`, `sync-state.json` (email and Slack check memory). Proposals live in
`board.json`. Project names from old tasks become projects on their own.
Settings (`defaults write com.lozhka13.taskboard …`): `claudeModel` (sonnet), `claudeConfigDir`,
`claudeWorkingDir`, `claudePath`, `transcriptionLocale` (en-US).
