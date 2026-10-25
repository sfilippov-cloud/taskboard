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

Tasks are grouped by project. In the board window: the project picker on top (`+` — new, sliders — settings)
and the tabs **Board / Journal / Documents**.

- **Journal** — a Markdown file per project (`projects/<slug>/log.md`); the general one is `log.md` in the
  data folder. Task changes (new, moved between columns, deleted) are written automatically wherever they
  come from: widget, board, voice or Claude. The rest (meeting outcomes, decisions, deadlines) is written by
  Claude through `log_entry`, or by you in the Journal tab.
- **Documents and notes**: drop a file on the widget or the board window, press "File" / "Note". The file is
  copied to `projects/<slug>/docs/` (without a project — to `inbox/`), Claude reads the text (txt, md, pdf,
  rtf, docx), logs the gist, creates tasks from explicit next steps (at most seven), and, with no project
  given, picks one by content or leaves the document in the inbox. If Claude is unavailable the file is
  still saved and noted in the journal.
- Claude sees documents as **data**, not instructions, and has only the `taskboard` tools.
- A project must exist: MCP rejects an unknown name and lists the known ones; a new one is created only
  explicitly (`create_project`).

MCP tools: `list_projects`, `create_project`, `update_project`, `log_entry`, `read_log`,
`list_documents`, `read_document`, `file_document`.

## Install

```bash
./install.sh   # builds, installs to /Applications, connects the taskboard MCP to ~/.claude-wingform
```

On the first recording macOS asks for microphone and speech-recognition access. Launch at login is in the menu.

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
`inbox/`, `projects/<slug>/{log.md,docs/}`. Project names from old tasks become projects on their own.
Settings (`defaults write com.lozhka13.taskboard …`): `claudeModel` (sonnet), `claudeConfigDir`,
`claudeWorkingDir`, `claudePath`, `transcriptionLocale` (en-US).
