'use strict';

function quote(value) { return "'" + String(value).replace(/'/g, "'\\''") + "'"; }
function payload(action, path) { return JSON.stringify({action: action, path: path}); }
function parseQuery(query) {
    var match = String(query || '').trim().match(/^(add|delete)(?:\s+(.*))?$/);
    return match ? {mode: match[1], text: (match[2] || '').trim()} :
        {mode: 'search', text: String(query || '').trim()};
}
function expandPath(path, home) {
    path = path.trim();
    if ((path[0] === '"' && path.slice(-1) === '"') ||
        (path[0] === "'" && path.slice(-1) === "'")) path = path.slice(1, -1);
    return path === '~' ? home : path.replace(/^~\//, home + '/');
}
function folderItem(path, deleting) {
    var item = {title: path.split('/').filter(Boolean).pop() || '/', subtitle: path,
        arg: payload(deleting ? 'remove' : 'open', path),
        icon: {type: 'fileicon', path: path}, text: {copy: path, largetype: path},
        quicklookurl: path, action: {file: path}};
    if (deleting) item.subtitle = 'Remove from zoxide only (confirmation required): ' + path;
    else item.mods = {
        cmd: {arg: payload('parent', path), subtitle: 'Open parent folder in Finder'},
        ctrl: {arg: payload('terminal', path), subtitle: 'Open in configured terminal'},
        shift: {arg: payload('copy', path), subtitle: 'Copy folder path'}
    };
    return item;
}

function runtime() {
    ObjC.import('Foundation');
    var app = Application.currentApplication();
    app.includeStandardAdditions = true;
    var fm = $.NSFileManager.defaultManager;
    function env(key) {
        var value = $.NSProcessInfo.processInfo.environment.objectForKey($(key));
        return value.isNil() ? '' : ObjC.unwrap(value);
    }
    var home = ObjC.unwrap($.NSHomeDirectory());
    function shell(command) { return app.doShellScript(command); }
    function directory(path) {
        var isDir = Ref();
        return Boolean(fm.fileExistsAtPathIsDirectory($(path), isDir) && isDir[0]);
    }
    function binary() {
        var explicit = env('zoxide_path');
        var candidates = explicit ? [expandPath(explicit, home)] :
            ['/opt/homebrew/bin/zoxide', '/usr/local/bin/zoxide', home + '/.local/bin/zoxide', home + '/.cargo/bin/zoxide'];
        for (var i = 0; i < candidates.length; i++) {
            if (fm.isExecutableFileAtPath($(candidates[i])) && !directory(candidates[i])) return candidates[i];
        }
        throw new Error('Install zoxide (brew install zoxide), or set its absolute binary path in Configure Workflow.');
    }
    function zoxide(args) {
        // Alfred exports blank optional settings too. An empty _ZO_DATA_DIR is
        // invalid to zoxide, so remove it rather than inheriting it into the child.
        var prefix = '/usr/bin/env -u _ZO_DATA_DIR -u XDG_DATA_HOME ';
        ['_ZO_DATA_DIR', 'XDG_DATA_HOME', '_ZO_EXCLUDE_DIRS', '_ZO_MAXAGE', '_ZO_RESOLVE_SYMLINKS'].forEach(function (key) {
            var value = env(key);
            if (value && (key === '_ZO_DATA_DIR' || key === 'XDG_DATA_HOME')) value = expandPath(value, home);
            if (value) prefix += key + '=' + quote(value) + ' ';
        });
        return shell(prefix + quote(binary()) + ' ' + args.map(quote).join(' '));
    }
    function search(query) {
        binary();
        var parsed = parseQuery(query);
        if (parsed.mode === 'add') {
            // Folder names are handled by the native "z add" File Filter.
            // Keep explicit paths available without adding competing result rows.
            if (!parsed.text) return {items: []};
            var path = expandPath(parsed.text, home);
            if (path[0] !== '/') return {items: []};
            var valid = path[0] === '/' && directory(path);
            return {items: [{title: valid ? 'Add folder to zoxide' : 'Enter an existing absolute folder path',
                subtitle: path, valid: valid, arg: payload('add', path)}]};
        }
        var args = ['query', '--list'];
        if (parsed.mode === 'delete') args.push('--all');
        args.push('--');
        if (parsed.text) args = args.concat(parsed.text.split(/\s+/));
        var output;
        try { output = zoxide(args); }
        catch (error) {
            if (String(error).indexOf('no match found') < 0) throw error;
            output = '';
        }
        var paths = output ? output.split(/\r\n|\r|\n/).filter(Boolean) : [];
        return {items: paths.length ? paths.map(function (path) {
            return folderItem(path, parsed.mode === 'delete');
        }) : [{title: 'No matching folders', subtitle: 'No match in the installed zoxide database. Check the optional data directory override in Configure Workflow.', valid: false}]};
    }
    function action(raw) {
        var data = JSON.parse(raw), path = data.path;
        if (data.action === 'pick') {
            try { path = String(app.chooseFolder({withPrompt: 'Add folder to zoxide'})); }
            catch (error) { if (error.errorNumber === -128 || String(error).indexOf('canceled') >= 0) return ''; throw error; }
            data.action = 'add';
        }
        if (typeof path !== 'string' || path[0] !== '/') throw new Error('An absolute folder path is required.');
        if (data.action === 'remove') {
            try { app.displayDialog('Remove this entry from zoxide?\n\n' + path + '\n\nNo files will be deleted.',
                {buttons: ['Cancel', 'Remove'], defaultButton: 'Cancel', cancelButton: 'Cancel'}); }
            catch (error) { if (error.errorNumber === -128 || String(error).indexOf('canceled') >= 0) return ''; throw error; }
            zoxide(['remove', '--', path]);
            return 'Removed from zoxide: ' + path;
        }
        if (data.action === 'copy') { app.setTheClipboardTo(path); return 'Copied: ' + path; }
        if (!directory(path)) throw new Error('Folder no longer exists: ' + path);
        if (data.action === 'add') { zoxide(['add', '--', path]); return 'Added to zoxide: ' + path; }
        if (data.action === 'open' || data.action === 'parent') {
            var target = data.action === 'parent' ? ObjC.unwrap($(path).stringByDeletingLastPathComponent) : path;
            shell('/usr/bin/open -a Finder ' + quote(target));
        } else if (data.action === 'terminal') {
            var terminalApp = env('terminal_app');
                        var terminal = env('terminal') || 'Terminal';
                        if (terminalApp) {
                            terminalApp = expandPath(terminalApp, home);
                            if (terminalApp[0] !== '/' || !directory(terminalApp) || !/\.app\/?$/.test(terminalApp)) {
                                throw new Error('Choose an installed terminal .app in Configure Workflow.');
                            }
                            terminal = terminalApp.replace(/\/$/, '').split('/').pop().replace(/\.app$/, '');
                        }
            if (terminal === 'Terminal') {
                var term = Application('com.apple.Terminal');
                term.activate();
                // No shell startup interpolation: a single quoted absolute path follows cd.
                term.doScript('cd -- ' + quote(path));
            } else if (terminal === 'iTerm2') {
                var iterm = Application('com.googlecode.iterm2');
                iterm.activate();
                var win = iterm.createWindowWithDefaultProfile();
                win.currentSession.write({text: 'cd -- ' + quote(path)});
            } else if (terminalApp || terminal === 'Warp' || terminal === 'Ghostty') {
                shell('/usr/bin/open -a ' + quote(terminalApp || terminal) + ' ' + quote(path));
            } else throw new Error('Choose your terminal application in Configure Workflow.');
        } else throw new Error('Unknown action: ' + data.action);
        // Opening via Alfred counts as a visit, just like navigating with z.
        zoxide(['add', '--', path]);
        return '';
    }
    return {search: search, action: action};
}
function run(argv) {
    try {
        var api = runtime();
        if (argv[0] === 'add-path') return api.action(payload('add', argv[1]));
        return argv[0] === 'action' ? api.action(argv[1]) : JSON.stringify(api.search(argv[1] || ''));
    } catch (error) {
        var message = String(error.message || error);
        return argv[0] === 'action' || argv[0] === 'add-path' ? 'Zoxide: ' + message : JSON.stringify({items: [
            {title: 'Zoxide needs attention', subtitle: message, valid: false}
        ]});
    }
}
if (typeof module !== 'undefined') module.exports = {quote: quote, parseQuery: parseQuery, expandPath: expandPath, folderItem: folderItem};
