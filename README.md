# Taskboard

Личный канбан в menu bar macOS: голосом по хоткею, Claude (профиль wingform) раскладывает сказанное
по задачам, список — полупрозрачным виджетом в правом верхнем углу.

| Хоткей | Что делает |
|---|---|
| `⌃⌥⌘T` | начать / закончить голосовую заметку |
| `Esc` | отменить запись (только пока она идёт) |
| `⌃⌥⌘K` | открыть доску |

Заметка → расшифровка на маке (Speech, русский) → `claude -p` с `CLAUDE_CONFIG_DIR=~/.claude-wingform`,
которому доступны только инструменты `taskboard` → задачи на доске. Если Claude недоступен или ничего не
изменил, заметка всё равно попадает на доску задачей как есть.

Виджет: «В работе», затем «Сделать», до 10 строк; кружок — отметить готовым, заголовок — открыть доску.
Скрыт от записи экрана и демонстрации (`defaults write com.lozhka13.taskboard widgetCapturable -bool true` — показать).
Доска: перетаскивание между колонками, двойной клик — правка, правый клик — приоритет, удаление.
«Готово» старше недели уходит в `archive.jsonl`.

## Установка

```bash
./install.sh   # собирает, ставит в /Applications, подключает MCP taskboard к ~/.claude-wingform
```

При первой записи macOS спросит доступ к микрофону и распознаванию речи. Автозапуск — в меню.

## Claude

MCP-сервер `taskboard-mcp` лежит в бандле: `list_tasks`, `add_task`, `update_task`, `move_task`,
`delete_task`. Подключён только к профилю wingform, так что в обычной сессии `wingform` можно сказать
«закинь на доску…» или «отметь #12 готовой».

## Данные

`~/Library/Application Support/Taskboard/`: `board.json` (доска, пишется под flock приложением и MCP),
`archive.jsonl`, `voice/*.txt` (расшифровки). Настройки (`defaults write com.lozhka13.taskboard …`):
`claudeModel` (sonnet), `claudeConfigDir`, `claudeWorkingDir`, `claudePath`, `transcriptionLocale` (ru-RU).
