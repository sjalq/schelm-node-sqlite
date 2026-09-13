'use strict';
const cp = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const schelm = process.env.SCHELM || path.join(os.homedir(), '.local/bin/schelm');
const nodeBin = process.execPath;
const defaultHome = path.resolve(os.homedir(), '.schelm');

if (!fs.existsSync(schelm)) {
    throw new Error('schelm not found at ' + schelm);
}

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'schelm-sqlite-gate-'));
const schelmHome = fs.mkdtempSync(path.join(tmpRoot, 'home-'));
const appDir = path.join(tmpRoot, 'app');
const srcRepo = path.join(tmpRoot, 'pkg.git');
if (path.resolve(schelmHome) === defaultHome) {
    throw new Error('refusing to use ~/.schelm');
}

function log() {
    console.log(...arguments);
}

function run(bin, args, opts = {}) {
    log('+', bin, ...args);
    return cp.execFileSync(bin, args, {
        cwd: opts.cwd || root,
        env: opts.env || process.env,
        input: opts.input,
        stdio: opts.stdio || 'inherit',
        encoding: opts.encoding
    });
}

function copyPackage(dest) {
    fs.rmSync(dest, { recursive: true, force: true });
    fs.mkdirSync(dest, { recursive: true });
    const tracked = run('git', ['ls-files'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] });
    const extra = run('git', ['ls-files', '--others', '--exclude-standard'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] });
    const files = (tracked + '\n' + extra).split('\n').map((x) => x.trim()).filter(Boolean);
    for (const rel of files) {
        const from = path.join(root, rel);
        if (!fs.existsSync(from) || fs.statSync(from).isDirectory()) continue;
        const to = path.join(dest, rel);
        fs.mkdirSync(path.dirname(to), { recursive: true });
        fs.cpSync(from, to);
    }
}

function taggedSource() {
    copyPackage(srcRepo);
    run('git', ['init', '-q'], { cwd: srcRepo });
    run('git', ['add', '-A'], { cwd: srcRepo });
    run('git', ['-c', 'user.email=gate@local', '-c', 'user.name=gate', 'commit', '-q', '-m', 'schelm-node-sqlite 1.0.3 gate source'], { cwd: srcRepo });
    run('git', ['tag', '1.0.3'], { cwd: srcRepo });
    return srcRepo;
}

function installApp(fromRepo) {
    fs.rmSync(appDir, { recursive: true, force: true });
    fs.mkdirSync(path.join(appDir, 'src'), { recursive: true });
    fs.writeFileSync(path.join(appDir, 'elm.json'), JSON.stringify({
        type: 'application',
        'source-directories': ['src'],
        'elm-version': '0.19.1',
        dependencies: {
            direct: { 'elm/bytes': '1.0.8', 'elm/core': '1.0.5', 'elm/json': '1.1.3' },
            indirect: {}
        },
        'test-dependencies': { direct: {}, indirect: {} }
    }, null, 4) + '\n');
    fs.cpSync(path.join(root, 'fixture-apps/schelm-gate/src/Main.elm'), path.join(appDir, 'src/Main.elm'));
    const env = { ...process.env, SCHELM_HOME: schelmHome, ELM_HOME: schelmHome };
    if (path.resolve(env.SCHELM_HOME) === defaultHome) {
        throw new Error('SCHELM_HOME resolved to ~/.schelm');
    }
    for (const pkg of ['elm/json', 'elm/bytes']) {
        run(schelm, ['install', pkg], { cwd: appDir, env, input: 'Y\n', stdio: ['pipe', 'inherit', 'inherit'] });
    }
    run(schelm, ['install', 'sjalq/schelm-node-sqlite', '--from=' + fromRepo], { cwd: appDir, env, input: 'Y\n', stdio: ['pipe', 'inherit', 'inherit'] });
    return env;
}

function compile(env, optimize, output) {
    const args = ['make', 'src/Main.elm', '--no-wire', '--output=' + output];
    if (optimize) args.push('--optimize');
    run(schelm, args, { cwd: appDir, env });
}

function runBundle(bundle, dbPath) {
    const runner = path.join(tmpRoot, 'run-' + path.basename(bundle) + '.cjs');
    fs.writeFileSync(runner, `'use strict';
const Elm = require(${JSON.stringify(bundle)}).Elm;
const app = Elm.Main.init({ flags: { dbPath: ${JSON.stringify(dbPath)} } });
if (!app.ports || !app.ports.emit) { console.error('no emit port'); process.exit(6); }
const watchdog = setTimeout(() => { console.error('bundle-timeout'); process.exit(2); }, 20000);
app.ports.emit.subscribe((v) => {
  process.stdout.write(JSON.stringify(v) + '\\n');
  if (v && (v.op === 'close' || v.op === 'finished')) clearTimeout(watchdog);
});
`);
    const child = cp.spawn(nodeBin, [runner], { cwd: appDir, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (c) => { stdout += c; process.stdout.write(c); });
    child.stderr.on('data', (c) => { stderr += c; process.stderr.write(c); });
    return new Promise((resolve) => {
        let finishedAt = 0;
        const hang = setTimeout(() => {
            try { child.kill('SIGKILL'); } catch (_) {}
        }, 25000);
        const onData = () => {
            if (!finishedAt && (stdout.includes('"op":"close"') || stdout.includes('"op":"finished"'))) {
                finishedAt = Date.now();
                setTimeout(() => {
                    if (child.exitCode === null && child.signalCode === null) {
                        try { child.kill('SIGKILL'); } catch (_) {}
                    }
                }, 3000);
            }
        };
        child.stdout.on('data', onData);
        child.on('exit', (code, signal) => {
            clearTimeout(hang);
            const natural = finishedAt > 0 && code === 0 && !signal;
            resolve({ code, signal, stdout, stderr, natural, waitedMs: finishedAt ? Date.now() - finishedAt : null });
        });
    });
}

function parseLines(stdout) {
    return stdout.split('\n').map((l) => l.trim()).filter(Boolean).map((l) => JSON.parse(l));
}

function expect(lines, op, outcome, check) {
    const hit = lines.find((l) => l.op === op);
    if (!hit) throw new Error('missing op ' + op + ' in ' + JSON.stringify(lines.map((l) => l.op)));
    if (hit.outcome !== outcome) throw new Error(op + ' expected ' + outcome + ' got ' + JSON.stringify(hit));
    if (check) check(hit.detail);
}

function checkRun(label, result) {
    log('gate-run', label, 'code=' + result.code, 'natural=' + result.natural, 'waitedMs=' + result.waitedMs);
    if (result.code !== 0) throw new Error(label + ' bundle exited ' + result.code + ' signal=' + result.signal);
    if (!result.natural) throw new Error(label + ' did not exit naturally after close');
    const lines = parseLines(result.stdout);
    expect(lines, 'execute.create', 'Ok');
    expect(lines, 'execute.insert', 'Ok', (d) => {
        if (d.changedRows !== 1) throw new Error('insert changedRows ' + JSON.stringify(d));
    });
    expect(lines, 'queryAll', 'Ok', (d) => {
        if (!Array.isArray(d) || d[0] !== 'alpha') throw new Error('queryAll ' + JSON.stringify(d));
    });
    expect(lines, 'queryOne', 'Ok', (d) => {
        if (d !== 'alpha') throw new Error('queryOne ' + JSON.stringify(d));
    });
    expect(lines, 'queryMaybe', 'Ok', (d) => {
        if (d !== null) throw new Error('queryMaybe ' + JSON.stringify(d));
    });
    expect(lines, 'transaction', 'Ok', (d) => {
        if (d !== 2) throw new Error('transaction count ' + JSON.stringify(d));
    });
    expect(lines, 'execute.after-tx', 'Ok');
    expect(lines, 'batch.order', 'Ok', (d) => {
        if (!Array.isArray(d) || d.join(',') !== 'first,second') throw new Error('batch order ' + JSON.stringify(d));
    });
    expect(lines, 'close', 'Ok');
}

(async () => {
    log('schelm-gate', 'node=' + process.version, 'platform=' + process.platform, 'arch=' + os.arch(), 'schelm=' + schelm, 'SCHELM_HOME=' + schelmHome);
    const fromRepo = taggedSource();
    const env = installApp(fromRepo);
    const debugJs = path.join(tmpRoot, 'out-debug.js');
    const optJs = path.join(tmpRoot, 'out-opt.js');
    compile(env, false, debugJs);
    compile(env, true, optJs);
    const debugDb = path.join(tmpRoot, 'debug.sqlite');
    const optDb = path.join(tmpRoot, 'opt.sqlite');
    const debug = await runBundle(debugJs, debugDb);
    checkRun('debug', debug);
    const opt = await runBundle(optJs, optDb);
    checkRun('optimize', opt);
    log('schelm-gate-ok', JSON.stringify({
        node: process.version,
        platform: process.platform,
        arch: os.arch(),
        sqlite: process.versions.sqlite,
        schelmHome,
        usedDefaultSchelmHome: path.resolve(schelmHome) === defaultHome
    }));
})().catch((err) => {
    console.error(err && err.stack || err);
    process.exit(1);
});
