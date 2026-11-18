# Zoxide for Alfred

An Alfred workflow that uses **your installed macOS `zoxide` binary and its database**, not a bundled copy or a separate index.

## Requirements and installation

- An **Apple Silicon Mac (arm64), macOS 12 or later**, and Alfred 5+ with the Powerpack (required for workflows). Intel Macs are not supported.
- Installed [zoxide](https://github.com/ajeetdsouza/zoxide), e.g. `brew install zoxide`.
- Download **Zoxide.alfredworkflow** from the [latest release](https://github.com/jhnmks/zoxide_alfred/releases/latest) and open it to import into Alfred.
- To build from source instead: install Xcode Command Line Tools (`xcode-select --install`), run `swift tools/build.swift`, then open `dist/Zoxide.alfredworkflow`.
- Click **Configure Workflow…** to choose your terminal and optionally override the binary or database directory.

Version 2.0.0 uses a native, compiled Swift helper (`zoxide-helper`), built for Apple Silicon and ad-hoc signed. Runtime, build tooling, icon generation, and automated tests use Swift; **Python and Node are not required**. Installed workflows do not require Swift development tools. No shell plugin or shell initialization is needed. The helper invokes your installed zoxide directly with argument arrays, without a shell. Folder dialogs, confirmation, and clipboard handling use AppKit. Terminal and iTerm2 automation use `NSAppleScript` from Swift; there is no JavaScript runtime or `osascript` subprocess.

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

`add`, `remove`, and `delete` are reserved as the first word. Use another part of a folder's path to search for folders with those names. Search terms are split on whitespace and passed literally to zoxide; shell syntax and environment variables are not evaluated. Adding by name uses Alfred's Spotlight-backed File Filter and searches indexed folders, including ones not yet in zoxide. Hidden or Spotlight-excluded folders may not appear; use an absolute path, `~/…`, or the Finder Universal Action for those. Newlines in directory names are unsupported by zoxide's line-oriented query output.

## Remove several records with Alfred's File Buffer

1. Type `z remove` or `z remove project` (`z delete` remains an alias).
2. Highlight a folder and press **Option-Down** to put it in Alfred's File Buffer and move to the next result. **Option-Up** adds without moving.
3. Repeat for the folders you want to remove. You can change the search to find other records without clearing the buffer.
4. Press **Option-Right** to action the buffer, then choose **Remove from zoxide**. A single Universal Action accepts files and text together, including mixed buffers of existing folders and missing-folder paths that Alfred classifies as text.
5. Review the paths and confirm **Remove** once for the batch. **Cancel** changes nothing.

**Option-Left** removes the last buffered item; **Option-Backspace** clears the buffer. These shortcuts are configurable in Alfred Preferences → Features → File Search → Buffer. Clear the buffer before starting if it contains unrelated items.

Selections must match database entries exactly, or resolve to one unique stored entry through filesystem aliases (for example `/var` and `/private/var` on macOS). Confirmation and removal use the original stored path. Unrelated or ambiguous paths abort the entire batch before confirmation. Plain Enter on a `z remove` result still removes just that record after confirmation. Batch removal deduplicates paths and reports individual failures without deleting files. Existing folders selected together in Finder can also use the **Remove from zoxide** Universal Action. Stale records are displayed with `file:skipcheck`, but Alfred may not allow nonexistent folders into its native File Buffer; use plain Enter for those.

## Add from Finder (Universal Action)

Select a single folder in Finder, invoke Alfred's **Universal Actions** hotkey (configure it in Alfred Preferences → Features → Universal Actions), and choose **Add to zoxide**. You can also action a folder result inside Alfred and select **Add to zoxide**.

The action accepts one selection at a time. Alfred's file Universal Actions include both files and folders, so it may also appear for files; the action checks the selection and rejects anything that is not an existing folder. It uses the same configured binary and database as `z add`, checks that the folder exists, and shows a notification after adding it. It does not need Finder scripting or additional Automation permissions.

## Settings

All three settings use Alfred's native **file picker**, opening the standard macOS browsing dialog. Use Cmd-Shift-G to enter a path and Cmd-Shift-. to show hidden files. Folder creation and search are provided where available by the system dialog; do not create a new database folder if you want to use existing records.

- **Terminal application:** choose your installed terminal `.app` using the picker. Leave blank to preserve the previous terminal choice, or use Terminal on a fresh installation. Terminal and iTerm2 receive a safely quoted `cd` command in a new session. Other applications (including Warp and Ghostty) use macOS's open-folder handler; behavior depends on the application's version and configuration.
- **Zoxide binary:** optional file picker for your installed executable; leave blank for auto-detection. Default locations are `/opt/homebrew/bin/zoxide`, `/usr/local/bin/zoxide`, `~/.local/bin/zoxide`, and `~/.cargo/bin/zoxide`. No login shell is launched, so custom shell aliases and PATH changes are not used.
- **Zoxide data directory:** optional folder picker; leave empty to use the existing default zoxide database. Blank overrides are removed from the zoxide subprocess environment, not treated as a separate database. If your shell sets `_ZO_DATA_DIR`, set the same **absolute path** here. Alfred does not inherit interactive shell configuration. Advanced zoxide settings (`_ZO_EXCLUDE_DIRS`, `_ZO_MAXAGE`, `_ZO_RESOLVE_SYMLINKS`) may also be supplied as workflow environment variables.

The bundled helper is ad-hoc signed, not Developer ID signed or notarized. macOS security behavior for downloaded archives still needs a clean-machine smoke test; local automated tests do not establish Gatekeeper compatibility. Do not disable Gatekeeper globally.

macOS may prompt for Automation access when controlling Terminal or iTerm2. Allow it under **System Settings → Privacy & Security → Automation**. Missing binaries and other errors appear in Alfred's results or a notification. Use Alfred's workflow debugger if notifications are disabled.

## Development

```sh
swift tools/build.swift
swift tests/workflow.swift
plutil -lint workflow/info.plist
```

Build first, then run the dependency-free Swift test script on Apple Silicon with zoxide installed. Tests check the archive, arm64 binary, signature, plist settings, command parsing, modifier payloads, literal special-character paths, and real helper/zoxide queries and writes against temporary isolated databases. HOME and data-directory overrides are isolated so tests never change your normal zoxide database. Batch tests use the read-only `validate-removal` command, which returns original stored paths without removing records or opening confirmation UI. GUI interactions, cancellation, partial removal failures, and terminal integration require a manual smoke test in Alfred after import:

1. Configure the terminal and binary path.
2. Add a temporary folder using a typed path, `z add` folder-name search, and Finder's **Add to zoxide** Universal Action. Check that a file selection is rejected without adding a record and multiple selections are not accepted.
3. Search for it, test Enter and all three modifiers.
4. Delete the record, cancel once, then confirm. Also buffer several records, cancel the batch, then confirm once. Verify all directories still exist. To check partial-failure reporting, make a selected record unavailable to zoxide after confirmation is displayed but before accepting; successful removals should still be reported alongside failures.
5. Test empty results, an unavailable binary path, and an unavailable folder in `z delete`.

`workflow/info.plist` is the checked-in workflow template: edit it for workflow graph, UI, and configuration changes. `tools/build.swift` loads that template, preserves its schema and settings, updates helper commands, embeds this README, and sets version `2.0.0`. It compiles `workflow/main.swift` with `swiftc -O -target arm64-apple-macosx12.0`, marks the helper executable, ad-hoc signs it, and runs `tools/icon.swift` to regenerate the icon. Foundation `Process` invokes the macOS tools directly without shell interpolation or third-party dependencies. The archive contains exactly `info.plist`, `zoxide-helper`, `icon.png`, and `README.md` at its root and preserves the helper's executable permissions. The build archive is in `dist/`; it and `workflow/zoxide-helper` are ignored by Git.

## Possible next features


- Per-folder terminal profiles or editor actions.
- An opt-in bulk cleanup action for stale records, with preview and confirmation.

These are deliberately not enabled automatically: they require additional permissions or could change records in bulk.
