#!/usr/bin/env python3
"""Build a self-contained Alfred workflow using only Python's standard library."""
from pathlib import Path
import plistlib
import zipfile
from icon import make_icon

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / "workflow"
FILTER = "38D1A3C6-5A26-44BD-9DD7-89D19EAA578A"
ACTION = "A671DAA1-3A25-4190-A9E8-82A26C46366D"
NOTIFY = "530ED2E5-D251-41C0-A7FC-C9B39F926681"
FILE_ACTION = "6A89B2AF-096D-4AB8-8850-901E7389D826"
ADD_FOLDER = "A6D23031-E68B-4587-969D-EFCD0B0FF74C"
ADD_SEARCH = "127EC551-CF84-4CF7-B0EA-B4CA641DFBC6"
DELETE_SEARCH = "92E22635-FF45-4E89-A2B0-F2755FAFC177"


def build():
    readme = (ROOT / "README.md").read_text()
    info = {
        "bundleid": "io.github.zoxide-alfred",
        "name": "Zoxide",
        "description": "Search, open, add, and remove folders using your installed zoxide.",
        "createdby": "jmokos",
        "version": "1.4.0",
        "disabled": False,
        "readme": readme,
        "webaddress": "https://github.com/jhnmks/zoxide_alfred",
        "variables": {"terminal_app": "", "zoxide_path": ""},
        "userconfigurationconfig": [
            {"type": "filepicker", "variable": "terminal_app", "label": "Preferred terminal application",
             "description": "Choose an installed terminal .app with the macOS file picker. Blank preserves your previous terminal choice or uses Terminal.",
             "config": {"default": "", "filtermode": 0, "required": False,
                        "placeholder": "Choose terminal application…"}},
            {"type": "filepicker", "variable": "zoxide_path", "label": "Zoxide binary (optional)",
             "description": "Absolute path to your installed zoxide. Homebrew, ~/.local/bin, and ~/.cargo/bin are detected automatically.",
             "config": {"default": "", "required": False, "filtermode": 0, "placeholder": "Auto-detect installed zoxide"}},
            {"type": "filepicker", "variable": "_ZO_DATA_DIR", "label": "Zoxide data directory (optional)",
             "description": "Leave empty for zoxide's default database. If your shell sets _ZO_DATA_DIR, enter the same absolute path here.",
             "config": {"default": "", "required": False, "filtermode": 1, "placeholder": "Use existing zoxide database"}},
        ],
        "objects": [
            {"uid": DELETE_SEARCH, "type": "alfred.workflow.input.scriptfilter", "version": 3,
             "config": {"keyword": "z delete", "title": "Remove a folder from zoxide",
                        "subtext": "Search recorded folders by name — files are never deleted",
                        "argumenttype": 1, "withspace": True, "alfredfiltersresults": False,
                        "script": '/usr/bin/osascript -l JavaScript ./zoxide.js delete-search "$1"',
                        "scriptargtype": 1, "type": 0, "escaping": 0,
                        "runningsubtext": "Searching zoxide records…", "queuedelaymode": 0,
                        "queuedelaycustom": 1, "queuedelayimmediatelyinitially": True,
                        "queuemode": 1}},
            {"uid": ADD_SEARCH, "type": "alfred.workflow.input.filefilter", "version": 0,
             "config": {"keyword": "z add", "title": "Add a folder to zoxide",
                        "subtext": "Type a folder name, then press Enter to add it",
                        "runningsubtext": "Searching folders…", "argumenttype": 0,
                        "withspace": True, "anchorfields": True, "daterange": 0,
                        "fields": [{"field": "kMDItemDisplayName", "not": False,
                                    "split": True, "value": "{query}", "words": True}],
                        "includesystem": False, "scopes": [], "types": ["public.folder"]}},
            {"uid": FILE_ACTION, "type": "alfred.workflow.trigger.universalaction", "version": 1,
             "config": {"name": "Add to zoxide", "acceptsfiles": True,
                        "acceptstext": False, "acceptsurls": False, "acceptsmulti": 0}},
            {"uid": ADD_FOLDER, "type": "alfred.workflow.action.script", "version": 2,
             "config": {"script": '/usr/bin/osascript -l JavaScript ./zoxide.js add-path "$1"',
                        "scriptargtype": 1, "type": 0, "escaping": 0}},
            {"uid": FILTER, "type": "alfred.workflow.input.scriptfilter", "version": 3,
             "config": {
                 "keyword": "z", "title": "Zoxide — search folders",
                 "subtext": "Enter: Finder · Cmd: parent · Ctrl: terminal · Shift: copy",
                 "argumenttype": 1, "withspace": True, "alfredfiltersresults": False,
                 "script": '/usr/bin/osascript -l JavaScript ./zoxide.js browse "$1"',
                 "scriptargtype": 1, "type": 0, "escaping": 0,
                 "runningsubtext": "Searching zoxide…", "queuedelaymode": 0,
                 "queuedelaycustom": 1, "queuedelayimmediatelyinitially": True,
                 "queuemode": 1}},
            {"uid": ACTION, "type": "alfred.workflow.action.script", "version": 2,
             "config": {"script": '/usr/bin/osascript -l JavaScript ./zoxide.js action "$1"',
                        "scriptargtype": 1, "type": 0, "escaping": 0}},
            {"uid": NOTIFY, "type": "alfred.workflow.output.notification", "version": 1,
             "config": {"title": "Zoxide", "text": "{query}", "onlyshowifquerypopulated": True,
                        "lastpathcomponent": False, "removeextension": False}},
        ],
        "connections": {
            DELETE_SEARCH: [{"destinationuid": ACTION, "modifiers": 0, "modifiersubtext": "Confirm removal from zoxide", "vitoclose": False}],
            ADD_SEARCH: [{"destinationuid": ADD_FOLDER, "modifiers": 0, "modifiersubtext": "", "vitoclose": False}],
            FILE_ACTION: [{"destinationuid": ADD_FOLDER, "modifiers": 0, "modifiersubtext": "", "vitoclose": False}],
            ADD_FOLDER: [{"destinationuid": NOTIFY, "modifiers": 0, "modifiersubtext": "", "vitoclose": False}],
            FILTER: [{"destinationuid": ACTION, "modifiers": 0, "modifiersubtext": "", "vitoclose": False}],
            ACTION: [{"destinationuid": NOTIFY, "modifiers": 0, "modifiersubtext": "", "vitoclose": False}],
        },
        "uidata": {
            DELETE_SEARCH: {"xpos": 60, "ypos": 600, "note": "Search existing records; confirmation before removal. Never deletes files."},
            ADD_SEARCH: {"xpos": 60, "ypos": 420},
            FILE_ACTION: {"xpos": 60, "ypos": 240}, ADD_FOLDER: {"xpos": 360, "ypos": 240},
            FILTER: {"xpos": 60, "ypos": 60, "note": "Enter: Finder | Cmd: parent | Ctrl: terminal | Shift: copy"}, ACTION: {"xpos": 360, "ypos": 60},
            NOTIFY: {"xpos": 660, "ypos": 60},
        },
    }
    make_icon(WORKFLOW / "icon.png")
    plist = WORKFLOW / "info.plist"
    plist.write_bytes(plistlib.dumps(info, sort_keys=False))
    output = ROOT / "dist" / "Zoxide.alfredworkflow"
    output.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.write(plist, "info.plist")
        archive.write(WORKFLOW / "zoxide.js", "zoxide.js")
        archive.write(WORKFLOW / "icon.png", "icon.png")
        archive.writestr("README.md", readme)
    print(output.relative_to(ROOT))


if __name__ == "__main__":
    build()
