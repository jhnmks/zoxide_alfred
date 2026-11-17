'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const {mkdtempSync, mkdirSync, rmSync, existsSync} = require('node:fs');
const {tmpdir} = require('node:os');
const {join, resolve} = require('node:path');
const {quote, parseQuery, expandPath, folderItem} = require('../workflow/zoxide.js');

test('shell quoting preserves special characters without evaluation', () => {
    for (const path of ["/tmp/it's a folder", '/tmp/$(touch nope); & "hi"', '/tmp/a\nb', '/tmp/é 📁']) {
        assert.equal(execFileSync('/bin/sh', ['-c', 'printf %s ' + quote(path)], {encoding: 'utf8'}), path);
    }
});
test('parse commands with optional arguments and do not reserve prefixes', () => {
    assert.deepEqual(parseQuery('add'), {mode: 'add', text: ''});
    assert.deepEqual(parseQuery('add ~/my projects'), {mode: 'add', text: '~/my projects'});
    assert.deepEqual(parseQuery('delete abc'), {mode: 'delete', text: 'abc'});
    assert.deepEqual(parseQuery('addition'), {mode: 'search', text: 'addition'});
    assert.deepEqual(parseQuery(' work api '), {mode: 'search', text: 'work api'});
});
test('expand only home shorthand and surrounding quotes', () => {
    assert.equal(expandPath('"~/my folder"', '/Users/test'), '/Users/test/my folder');
    assert.equal(expandPath('~', '/Users/test'), '/Users/test');
    assert.equal(expandPath('/tmp/$HOME', '/Users/test'), '/tmp/$HOME');
});
test('modifier payloads and deletion use distinct safe actions', () => {
    const path = "/tmp/it's a folder";
    const item = folderItem(path, false);
    assert.deepEqual(JSON.parse(item.arg), {action: 'open', path});
    for (const [key, action] of [['cmd', 'parent'], ['ctrl', 'terminal'], ['shift', 'copy']]) {
        assert.deepEqual(JSON.parse(item.mods[key].arg), {action, path});
    }
    assert.equal(item.uid, undefined, 'preserve zoxide rank, not Alfred learning');
    assert.equal(item.text.copy, path);
    const deleted = folderItem(path, true);
    assert.equal(JSON.parse(deleted.arg).action, 'remove');
    assert.equal(deleted.mods, undefined);
});

test('builder creates a valid plist and installable archive', () => {
    const root = resolve(__dirname, '..');
    execFileSync('python3', ['tools/build.py'], {cwd: root});
    assert.ok(existsSync(join(root, 'dist/Zoxide.alfredworkflow')));
    execFileSync('python3', ['-c', [
        'import plistlib, zipfile',
        'from pathlib import Path',
        'p = plistlib.loads(Path("workflow/info.plist").read_bytes())',
        'assert p["bundleid"] == "io.github.zoxide-alfred"',
        'assert len(p["objects"]) == 7',
                'delete = next(o for o in p["objects"] if o.get("config", {}).get("keyword") == "z delete")',
                'assert delete["type"] == "alfred.workflow.input.scriptfilter"',
                'assert "delete-search" in delete["config"]["script"]',
                'assert p["connections"][delete["uid"]]',
                'search = next(o for o in p["objects"] if o["type"] == "alfred.workflow.input.filefilter")',
                'assert search["config"]["keyword"] == "z add"',
                'assert search["config"]["types"] == ["public.folder"]',
                'assert p["connections"][search["uid"]][0]["destinationuid"] == p["connections"][next(o["uid"] for o in p["objects"] if o["type"] == "alfred.workflow.trigger.universalaction")][0]["destinationuid"]',
        'ua = next(o for o in p["objects"] if o["type"] == "alfred.workflow.trigger.universalaction")',
        'assert ua["config"] == {"name": "Add to zoxide", "acceptsfiles": True, "acceptstext": False, "acceptsurls": False, "acceptsmulti": 0}',
        'assert "_ZO_DATA_DIR" not in p["variables"]',
        'controls = {c["variable"]: c for c in p["userconfigurationconfig"]}',
        'assert set(controls) == {"terminal_app", "zoxide_path", "_ZO_DATA_DIR"}',
        'assert all(c["type"] == "filepicker" for c in controls.values())',
        'assert controls["_ZO_DATA_DIR"]["config"]["filtermode"] == 1',
        'assert controls["zoxide_path"]["config"]["filtermode"] == 0',
                'dest = p["connections"][ua["uid"]][0]["destinationuid"]',
                'script = next(o for o in p["objects"] if o["uid"] == dest)',
                'assert "add-path" in script["config"]["script"]',
        'with zipfile.ZipFile("dist/Zoxide.alfredworkflow") as z:',
        '    assert z.testzip() is None',
        '    assert set(z.namelist()) == {"info.plist", "zoxide.js", "icon.png", "README.md"}',
        '    assert z.read("zoxide.js") == Path("workflow/zoxide.js").read_bytes()',
                '    icon = z.read("icon.png")',
                '    assert icon[:8] == bytes([137, 80, 78, 71, 13, 10, 26, 10])',
                '    assert int.from_bytes(icon[16:20], "big") == 512'
    ].join('\n')], {cwd: root});
});

const binary = ['/opt/homebrew/bin/zoxide', '/usr/local/bin/zoxide'].find(existsSync);
test('real JXA uses isolated installed zoxide, supports add/search and errors', {
    skip: process.platform !== 'darwin' || !binary
}, () => {
    const root = mkdtempSync(join(tmpdir(), 'alfred-zoxide-test-'));
    const db = join(root, 'database');
    const path = join(root, "test it's a folder; $(echo injected)");
    mkdirSync(db); mkdirSync(path);
    const env = {...process.env, _ZO_DATA_DIR: db, zoxide_path: binary};
    const script = resolve(__dirname, '../workflow/zoxide.js');
    const invoke = (mode, arg, overrides = {}) => execFileSync('/usr/bin/osascript',
        ['-l', 'JavaScript', script, mode, arg], {env: {...env, ...overrides}, encoding: 'utf8'}).trim();
    try {
        const initial = JSON.parse(invoke('search', ''));
        assert.equal(initial.items[0].valid, false);
        const add = JSON.parse(invoke('search', 'add ' + path)).items[0];
        assert.equal(add.valid, true);
        assert.match(invoke('action', add.arg), /Added to zoxide/);
        const matches = JSON.parse(invoke('search', 'folder'));
        assert.equal(JSON.parse(matches.items[0].arg).path, path);
        // A blank Alfred setting must fall back to zoxide's own database location.
        // HOME isolates that fallback so this regression cannot touch the real database.
        const fallbackHome = join(root, 'home');
        mkdirSync(fallbackHome);
        const fallbackEnv = {...env, HOME: fallbackHome};
        delete fallbackEnv._ZO_DATA_DIR;
        delete fallbackEnv.XDG_DATA_HOME;
        execFileSync(binary, ['add', '--', path], {env: fallbackEnv});
        const fallback = JSON.parse(execFileSync('/usr/bin/osascript',
            ['-l', 'JavaScript', script, 'search', 'folder'],
            {env: {...fallbackEnv, _ZO_DATA_DIR: '', XDG_DATA_HOME: ''}, encoding: 'utf8'}));
        assert.equal(JSON.parse(fallback.items[0].arg).path, path);
        const second = join(root, 'another record');
        mkdirSync(second);
        assert.match(invoke('add-path', second), /Added to zoxide/);
        const allPaths = JSON.parse(invoke('search', '')).items.map(item => JSON.parse(item.arg).path);
        assert.deepEqual(new Set(allPaths), new Set([path, second]));
        execFileSync(binary, ['remove', '--', second], {env});
        assert.deepEqual(JSON.parse(invoke('search', 'add')).items, []);
                assert.deepEqual(JSON.parse(invoke('search', 'add Projects')).items, []);
        assert.deepEqual(JSON.parse(invoke('browse', 'delete folder')).items, []);
                assert.deepEqual(JSON.parse(invoke('browse', 'add Projects')).items, []);
                assert.equal(JSON.parse(invoke('browse', 'folder')).items.length, 1);
                const deleted = JSON.parse(invoke('delete-search', 'folder')).items[0];
        assert.equal(JSON.parse(deleted.arg).action, 'remove');
        const invalid = JSON.parse(invoke('search', '', {zoxide_path: '/no/zoxide'}));
        assert.equal(invalid.items[0].title, 'Zoxide needs attention');
        assert.match(invalid.items[0].subtitle, /Install zoxide/);
        assert.equal(JSON.parse(invoke('search', 'add /does/not/exist')).items[0].valid, false);
                assert.match(invoke('add-path', '/does/not/exist'), /Folder no longer exists/);
                assert.match(invoke('add-path', script), /Folder no longer exists/);
                assert.match(invoke('add-path', 'relative/path'), /absolute folder path/);
                assert.match(invoke('add-path', path, {zoxide_path: '/no/zoxide'}), /Install zoxide/);
        // No UI: remove directly with zoxide and confirm the workflow sees the result.
        execFileSync(binary, ['remove', '--', path], {env});
        assert.equal(JSON.parse(invoke('search', 'folder')).items[0].valid, false);
        assert.ok(existsSync(path));
    } finally { rmSync(root, {recursive: true, force: true}); }
});
