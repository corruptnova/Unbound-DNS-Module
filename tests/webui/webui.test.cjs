// WebUI end-to-end: the page runs in Chromium with a fake `ksu.exec` that
// executes the real ctl.sh (against tests/stubs), so clicks go all the way
// through the control script.
//
//   node tests/webui/webui.test.cjs [--screenshots DIR]
'use strict';

const { chromium } = require('playwright');
const { execFileSync, spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const REPO = path.resolve(__dirname, '../..');
const SHOTS = process.argv.includes('--screenshots')
  ? path.resolve(process.argv[process.argv.indexOf('--screenshots') + 1]) : null;

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'unbound-webui-'));
const MOD = path.join(tmp, 'module');
const STATE = path.join(tmp, 'state');
fs.cpSync(path.join(REPO, 'module'), MOD, { recursive: true });
fs.mkdirSync(path.join(MOD, 'bin'), { recursive: true });
for (const f of fs.readdirSync(path.join(REPO, 'tests/stubs/bin'))) {
  fs.copyFileSync(path.join(REPO, 'tests/stubs/bin', f), path.join(MOD, 'bin', f));
  fs.chmodSync(path.join(MOD, 'bin', f), 0o755);
}
fs.writeFileSync(path.join(MOD, 'bin/BUILDINFO'), 'abi=x86_64\nunbound=1.26.2 openssl=3.5.9\n');
fs.writeFileSync(path.join(MOD, 'module.prop'), 'id=unbound-dns\nversion=v1.26.2-r1\n');
fs.mkdirSync(path.join(STATE, 'www'), { recursive: true });
fs.mkdirSync(path.join(STATE, 'settings'), { recursive: true });
fs.writeFileSync(path.join(STATE, 'settings/private_dns_mode'), 'off\n');
fs.writeFileSync(path.join(STATE, 'www/pro.txt'),
  Array.from({ length: 1500 }, (_, i) => `*.tracker${i}.example.net`).join('\n') + '\n*.ads.example.com\n');
fs.writeFileSync(path.join(tmp, 'ca.pem'), 'fake\n');

const shell = (() => {
  try { execFileSync('busybox', ['true']); return ['busybox', 'sh']; } catch { return ['sh']; }
})();
const env = {
  ...process.env,
  PATH: `${path.join(REPO, 'tests/stubs')}:${process.env.PATH}`,
  ASH_STANDALONE: '1',
  STUB_STATE: STATE,
  UNBOUND_MODDIR: MOD,
  UNBOUND_DATA: path.join(tmp, 'data'),
  UNBOUND_APPDATA: path.join(tmp, 'appdata'),
  UNBOUND_NO_BUSYBOX_REEXEC: '1',
  UNBOUND_POLL: '1',
  UNBOUND_IF_INET6: path.join(tmp, 'if_inet6'),
  UNBOUND_APPLY_TIMEOUT: '10',
  UNBOUND_CA_BUNDLE: path.join(tmp, 'ca.pem'),
};

const executed = [];
function run(cmd) {
  executed.push(cmd);
  const real = cmd.split('/data/adb/modules/unbound-dns').join(MOD);
  return new Promise((resolve) => {
    const p = spawn(shell[0], [...shell.slice(1), '-c', real], { env });
    let stdout = ''; let stderr = '';
    p.stdout.on('data', (d) => { stdout += d; });
    p.stderr.on('data', (d) => { stderr += d; });
    p.on('close', (code) => resolve({ errno: code, stdout, stderr }));
  });
}

let failures = 0;
function check(name, ok, detail = '') {
  if (ok) console.log(`ok   ${name}`);
  else { failures++; console.log(`FAIL ${name} ${detail}`); }
}

(async () => {
  const daemon = spawn(shell[0], [...shell.slice(1), path.join(MOD, 'ctl.sh'), 'daemon'], { env, stdio: 'ignore' });
  const browser = await chromium.launch();
  try {
    for (const scheme of ['light', 'dark']) {
      const page = await browser.newPage({ viewport: { width: 390, height: 844 }, colorScheme: scheme });
      const errors = [];
      page.on('pageerror', (e) => errors.push(e.message));
      await page.exposeFunction('__run', run);
      await page.addInitScript(() => {
        window.ksu = {
          exec(cmd, opts, cb) {
            window.__run(cmd).then((r) => window[cb](r.errno, r.stdout, r.stderr));
          },
        };
      });
      await page.goto('file://' + path.join(MOD, 'webroot/index.html'));

      if (scheme === 'light') {
        await page.waitForFunction(() => document.getElementById('status-text').textContent === 'Protecting all DNS', null, { timeout: 20000 });
        check('status shows protecting', true);
        check('version shown', (await page.textContent('#stats')).includes('1.26.2'));
        check('ipv6 status shown', (await page.textContent('#stats')).includes('Redirected'));
        check('custom url fields hidden for presets', !(await page.isVisible('#custom-url')));
        check('empty state shown', await page.isVisible('#sources-empty'));

        // Add a preset list; it downloads in the background.
        await page.selectOption('#preset', { label: 'HaGeZi Pro' });
        await page.click('#add-btn');
        await page.waitForFunction(() => document.getElementById('sources').textContent.includes('1,501 domains'), null, { timeout: 30000 });
        check('preset list added and downloaded', true);
        check('add command quoted', executed.some((c) => c.endsWith("'list-add' 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.txt' 'HaGeZi Pro'")));
        check('preset removed from picker', !(await page.textContent('#preset')).includes('HaGeZi Pro'));
        await page.waitForFunction(() => document.getElementById('blocked-total').textContent === '1,501 domains', null, { timeout: 10000 });
        check('blocked total updated', true);

        // Allowlist: normalised; hostile input is quoted and rejected.
        await page.fill('#allow-input', 'https://Ads.Example.com/path');
        await page.press('#allow-input', 'Enter');
        await page.waitForFunction(() => document.getElementById('allow').textContent.includes('ads.example.com'), null, { timeout: 10000 });
        check('allowlist entry added', true);
        await page.fill('#allow-input', "x.com';touch /tmp/pwned-unbound;'");
        await page.press('#allow-input', 'Enter');
        await page.waitForSelector('#toast.bad', { timeout: 10000 });
        check('bad domain rejected with error toast', (await page.textContent('#toast')).includes('invalid domain'));
        check('hostile input passed as one quoted argument',
          executed.some((c) => c.includes(`'allow-add' 'x.com'\\''`)));
        check('no command injection', !fs.existsSync('/tmp/pwned-unbound'));

        // Redirect off and on.
        await page.click('#redirect-btn');
        await page.waitForFunction(() => document.getElementById('status-text').textContent === 'Redirect off', null, { timeout: 15000 });
        check('redirect turned off', true);
        await page.click('#redirect-btn');
        await page.waitForFunction(() => document.getElementById('status-text').textContent === 'Protecting all DNS', null, { timeout: 15000 });
        check('redirect turned back on', true);

        // Names from the data directory are rendered as text, never HTML.
        const sources = path.join(env.UNBOUND_DATA, 'lists/sources.list');
        fs.appendFileSync(sources, 'aaaaaaaaaaaa\t0\t<img src=x onerror="window.__pwned=1">\thttps://evil.example/x\n');
        await page.reload();
        await page.waitForFunction(() => document.getElementById('sources').textContent.includes('<img'), null, { timeout: 10000 });
        check('html in names is not executed', !(await page.evaluate(() => window.__pwned)));
        check('html in names is not parsed', (await page.$$('#sources img')).length === 0);

        // Two-step remove.
        const btn = page.locator('button[aria-label^="Remove <img"]');
        await btn.click();
        check('remove asks first', (await btn.textContent()) === 'Remove?');
        await btn.click();
        await page.waitForFunction(() => !document.getElementById('sources').textContent.includes('<img'), null, { timeout: 10000 });
        check('list removed after confirm', true);

        await page.click('#log-details summary');
        await page.waitForFunction(() => document.getElementById('log').textContent.includes('lists: added'), null, { timeout: 10000 });
        check('log shows module log', true);
        await page.click('[data-log="diag"]');
        await page.waitForFunction(() => document.getElementById('log').textContent.includes('Unbound DNS module diagnostics'), null, { timeout: 15000 });
        check('diagnostics shown', (await page.textContent('#log')).includes('== redirect rules'));
        await page.click('#log-details summary');

        // My blocklist.
        await page.fill('#own-input', '*.Tracker.Example.net');
        await page.press('#own-input', 'Enter');
        await page.waitForFunction(() => document.getElementById('own').textContent.includes('tracker.example.net'), null, { timeout: 10000 });
        check('own blocklist entry added', true);
        check('own block command quoted', executed.some((c) => c.endsWith("'block-add' '*.Tracker.Example.net'")));
        await page.fill('#own-input', 'ads*.example.com');
        await page.press('#own-input', 'Enter');
        await page.waitForFunction(() => document.getElementById('toast').textContent.includes('partial patterns'), null, { timeout: 10000 });
        check('partial wildcard rejected with explanation', true);
      } else {
        await page.waitForFunction(() => document.getElementById('sources').textContent.includes('HaGeZi Pro'), null, { timeout: 20000 });
      }

      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
      check(`no horizontal scroll (${scheme})`, !overflow);
      if (SHOTS) {
        fs.mkdirSync(SHOTS, { recursive: true });
        await page.screenshot({ path: path.join(SHOTS, `webui-${scheme}.png`), fullPage: true });
      }

      // Settings page.
      await page.click('#settings-link');
      await page.waitForFunction(() => document.querySelector('input[name=RESOLVER]:checked') !== null, null, { timeout: 15000 });
      const data = env.UNBOUND_DATA;
      const clearToast = () => page.evaluate(() => { document.getElementById('toast').textContent = ''; });
      const settingsFile = () => (fs.existsSync(path.join(data, 'settings.conf')) ? fs.readFileSync(path.join(data, 'settings.conf'), 'utf8') : '');
      if (scheme === 'light') {
        check('settings page loads current resolver', (await page.inputValue('input[name=RESOLVER]:checked')) === 'recursive');
        check('apply bar hidden without changes', await page.isHidden('#apply-bar'));
        await page.check('input[name=RESOLVER][value=quad9]');
        check('apply bar appears on change', await page.isVisible('#apply-bar'));
        await clearToast();
        await page.click('#apply-btn');
        await page.waitForFunction(() => document.getElementById('toast').textContent === 'Applied', null, { timeout: 30000 });
        check('quad9 applied', settingsFile().includes('RESOLVER=quad9'));
        check('quad9 rendered', fs.readFileSync(path.join(data, 'options.conf'), 'utf8').includes('9.9.9.9@853#dns.quad9.net'));

        await page.check('input[name=RESOLVER][value=custom]');
        check('custom server box shown', await page.isVisible('#forwarders'));
        await page.fill('#forwarders', '1.2.3.4');
        await page.click('#apply-btn');
        await page.waitForSelector('#apply-error:not([hidden])', { timeout: 15000 });
        check('server without TLS name rejected', (await page.textContent('#apply-error')).includes('invalid server'));
        check('rejected change not saved', settingsFile().includes('RESOLVER=quad9'));
        await page.check('input[name=RESOLVER][value=custom]');
        await page.fill('#forwarders', '9.9.9.9 dns.quad9.net\n2620:fe::fe dns.quad9.net');
        await clearToast();
        await page.click('#apply-btn');
        await page.waitForFunction(() => document.getElementById('toast').textContent === 'Applied', null, { timeout: 30000 });
        check('custom servers stored', fs.readFileSync(path.join(data, 'forwarders.list'), 'utf8') === '9.9.9.9#dns.quad9.net\n2620:fe::fe#dns.quad9.net\n');

        await page.uncheck('input[name=DNSSEC]');
        check('dnssec-off warning shown', await page.isVisible('#dnssec-off-warning'));
        check('permissive disabled without validation', await page.isDisabled('input[name=DNSSEC_PERMISSIVE]'));
        await page.click('#discard-btn');
        check('discard restores the form', await page.isChecked('input[name=DNSSEC]'));

        await page.click('#advanced summary');
        await page.waitForFunction(() => document.getElementById('custom-conf').value.includes('Your own Unbound settings'), null, { timeout: 10000 });
        const customBefore = fs.readFileSync(path.join(data, 'custom.conf'), 'utf8');
        await page.fill('#custom-conf', 'server:\n    BROKEN: yes\n');
        await page.click('#custom-save');
        await page.waitForSelector('#apply-error:not([hidden])', { timeout: 40000 });
        check('broken custom.conf rolled back', (await page.textContent('#apply-error')).includes('previous settings are back'));
        check('custom.conf file restored', fs.readFileSync(path.join(data, 'custom.conf'), 'utf8') === customBefore);

        await clearToast();
        await page.click('#anchor-update');
        await page.waitForFunction(() => document.getElementById('toast').textContent.includes('up to date'), null, { timeout: 20000 });
        check('trust anchor check', true);
        check('anchor keys listed', (await page.textContent('#anchor-status')).includes('20326'));

        const restore = page.locator('button[aria-label="Restore all defaults"]');
        await restore.click();
        check('restore asks first', (await restore.textContent()) === 'Tap again to restore');
        await clearToast();
        await restore.click();
        await page.waitForFunction(() => document.getElementById('toast').textContent.includes('defaults'), null, { timeout: 30000 });
        check('defaults restored', !settingsFile().includes('RESOLVER='));
      }
      const overflowS = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
      check(`settings: no horizontal scroll (${scheme})`, !overflowS);
      if (SHOTS) {
        await page.screenshot({ path: path.join(SHOTS, `settings-${scheme}.png`), fullPage: true });
      }
      await page.click('#back-link');
      await page.waitForSelector('#status-text');
      check(`no page errors (${scheme})`, errors.length === 0, errors.join('; '));
      await page.close();
    }
  } finally {
    await browser.close();
    await run(`sh /data/adb/modules/unbound-dns/ctl.sh stop`);
    daemon.kill();
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  console.log(failures ? `webui: ${failures} failed` : 'webui: all passed');
  process.exit(failures ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
