# Zoxide for Alfred

An Alfred workflow that uses **your installed macOS `zoxide` binary and its database**, not a bundled copy or a separate index.

## Requirements and installation

- macOS and Alfred 5+ with the Powerpack (required for workflows).
- Installed [zoxide](https://github.com/ajeetdsouza/zoxide), e.g. `brew install zoxide`.
- Download **Zoxide.alfredworkflow** from the [latest release](https://github.com/jhnmks/zoxide_alfred/releases/latest) and open it to import into Alfred.
- To build from source instead: run `python3 tools/build.py`, then open `dist/Zoxide.alfredworkflow`.
- Click **Configure Workflow…** to choose your terminal and optionally override the binary or database directory.

The workflow runs with macOS's built-in JavaScript for Automation (`osascript`); Node and Python are **not required after installation**. No shell plugin or shell initialization is needed. Python 3 is used only for packaging; Node is used only for tests.

## Usage

- `z` — List folders already recorded by your installed zoxide, in ranking order. No re-adding or importing is needed.
- `z project` — Search with zoxide's native matching.
- `z work api` — Match multiple keywords.
- **Enter** — Open selected folder in Finder.
- **Cmd-Enter** — Open its parent folder in Finder.
- **Ctrl-Enter** — Open folder in configured terminal.
- **Shift-Enter** — Copy absolute folder path.
- **Cmd-C** — Copy absolute folder path using Alfred's copy action.
- `z add ~/Projects/my app` — Add an existing folder (spaces supported, quotes optional).
- `z add Projects` — Search folders by name using Alfred's native folder search. Select a result and press Enter to add it; no full path needed.
- `z add` — Start searching for a folder to add.
- `z delete project` — Find entries to remove; Enter asks for confirmation.
- `z delete` — List all entries for removal, including unavailable folders.

The workflow editor has separate inputs for `z` (search/open), `z add` (native folder-name search), and `z delete` (record-name search). Finder/parent/terminal/copy actions remain modifiers on `z` results. Delete intentionally uses a Script Filter backed by zoxide, not Spotlight, so only recorded entries—including missing folders—are offered.

Deletion **only removes a zoxide record**, never the directory or its files. Cancel is the default confirmation button. Opening a folder records a visit using `zoxide add`, so its rank evolves with usage. Copying a path does not change its rank.

`add` and `delete` are reserved as the first word. Use another part of a folder's path to search for folders with those names. Search terms are split on whitespace and passed literally to zoxide; shell syntax and environment variables are not evaluated. Adding by name uses Alfred's Spotlight-backed File Filter and searches indexed folders, including ones not yet in zoxide. Hidden or Spotlight-excluded folders may not appear; use an absolute path, `~/…`, or the Finder Universal Action for those. Newlines in directory names are unsupported by zoxide's line-oriented query output.

## Add from Finder (Universal Action)

Select a single folder in Finder, invoke Alfred's **Universal Actions** hotkey (configure it in Alfred Preferences → Features → Universal Actions), and choose **Add to zoxide**. You can also action a folder result inside Alfred and select **Add to zoxide**.

The action accepts one selection at a time. Alfred's file Universal Actions include both files and folders, so it may also appear for files; the action checks the selection and rejects anything that is not an existing folder. It uses the same configured binary and database as `z add`, checks that the folder exists, and shows a notification after adding it. It does not need Finder scripting or additional Automation permissions.

## Settings

All three settings use Alfred's native **file picker**, opening the standard macOS browsing dialog. Use Cmd-Shift-G to enter a path and Cmd-Shift-. to show hidden files. Folder creation and search are provided where available by the system dialog; do not create a new database folder if you want to use existing records.

- **Terminal application:** choose your installed terminal `.app` using the picker. Leave blank to preserve the previous terminal choice, or use Terminal on a fresh installation. Terminal and iTerm2 receive a safely quoted `cd` command in a new session. Other applications (including Warp and Ghostty) use macOS's open-folder handler; behavior depends on the application's version and configuration.
- **Zoxide binary:** optional file picker for your installed executable; leave blank for auto-detection. Default locations are `/opt/homebrew/bin/zoxide`, `/usr/local/bin/zoxide`, `~/.local/bin/zoxide`, and `~/.cargo/bin/zoxide`. No login shell is launched, so custom shell aliases and PATH changes are not used.
- **Zoxide data directory:** optional folder picker; leave empty to use the existing default zoxide database. Blank overrides are removed from the zoxide subprocess environment, not treated as a separate database. If your shell sets `_ZO_DATA_DIR`, set the same **absolute path** here. Alfred does not inherit interactive shell configuration. Advanced zoxide settings (`_ZO_EXCLUDE_DIRS`, `_ZO_MAXAGE`, `_ZO_RESOLVE_SYMLINKS`) may also be supplied as workflow environment variables.

macOS may prompt for Automation access when controlling Terminal or iTerm2. Allow it under **System Settings → Privacy & Security → Automation**. Missing binaries and other errors appear in Alfred's results or a notification. Use Alfred's workflow debugger if notifications are disabled.

## Development

```sh
node --test tests/*.test.js
python3 tools/build.py
plutil -lint workflow/info.plist
```

Tests cover command parsing, quoting, modifier output, packaging, and (on macOS with zoxide installed) real JXA/zoxide queries and writes against a temporary isolated database. They never change your normal zoxide database. GUI interactions and terminal integration require a manual smoke test in Alfred after import:

1. Configure the terminal and binary path.
2. Add a temporary folder using a typed path, `z add` folder-name search, and Finder's **Add to zoxide** Universal Action. Check that a file selection is rejected without adding a record and multiple selections are not accepted.
3. Search for it, test Enter and all three modifiers.
4. Delete the record, cancel once, then confirm. Verify the directory still exists.
5. Test empty results, an unavailable binary path, and an unavailable folder in `z delete`.

`workflow/info.plist` is generated by `tools/build.py`; change the builder rather than editing the plist directly. The build archive is in `dist/` (ignored by Git).

## Possible next features


- Per-folder terminal profiles or editor actions.
- An opt-in bulk cleanup action for stale records, with preview and confirmation.

These are deliberately not enabled automatically: they require additional permissions or could change records in bulk.
