'use strict';

const KEYS = ['RESOLVER', 'CACHE_SIZE', 'CACHE_MIN_TTL', 'CACHE_MAX_TTL', 'PREFETCH', 'SERVE_EXPIRED',
  'THREADS', 'DNSSEC', 'DNSSEC_PERMISSIVE', 'QNAME_MIN', 'REBIND_PROTECT', 'UPSTREAM_IPV6',
  'BLOCK_ANSWER', 'LOG_LEVEL'];

const form = $('settings-form');
let loaded = null; // last state read from ctl.sh: {settings, forwarders, anchor, ...}

function field(k) { return form.elements[k]; }

function readForm() {
  const v = {};
  for (const k of KEYS) {
    const f = field(k);
    if (f instanceof RadioNodeList) v[k] = f.value;
    else if (f.type === 'checkbox') v[k] = f.checked ? '1' : '0';
    else v[k] = String(f.value).trim();
  }
  return v;
}

function writeForm(s) {
  for (const k of KEYS) {
    const f = field(k);
    if (f instanceof RadioNodeList) f.value = s[k];
    else if (f.type === 'checkbox') f.checked = s[k] === '1';
    else f.value = s[k];
  }
}

// "address tls-name" lines <-> ctl.sh's "address#tls-name" items.
function forwardersFromText(text) {
  return text.split('\n').map((l) => l.trim()).filter(Boolean).map((l) => {
    if (l.includes('#')) return l.replace(/\s+/g, '');
    const [addr, name] = l.split(/\s+/);
    return name ? `${addr}#${name}` : addr;
  });
}
const forwardersToText = (list) => list.map((f) => f.replace('#', ' ')).join('\n');

function changes() {
  if (!loaded) return [];
  const cur = readForm();
  const out = KEYS.filter((k) => cur[k] !== loaded.settings[k]).map((k) => `${k}=${cur[k]}`);
  if (cur.RESOLVER === 'custom') {
    const fw = forwardersFromText($('forwarders').value);
    if (fw.join(',') !== loaded.forwarders.join(',')) out.push(`FORWARDERS=${fw.join(',')}`);
  }
  return out;
}

function refreshUi() {
  const cur = readForm();
  const c = changes();
  $('apply-bar').hidden = c.length === 0;
  $('apply-summary').textContent = `${c.length} unsaved change${c.length === 1 ? '' : 's'}`;
  $('custom-servers').hidden = cur.RESOLVER !== 'custom';
  field('DNSSEC_PERMISSIVE').disabled = cur.DNSSEC !== '1';
  $('dnssec-off-warning').hidden = cur.DNSSEC === '1';
}

function renderAnchor(a) {
  const keys = (a.keys || []).map((k) => `${k.id}${k.state ? ` (${k.state.toLowerCase()})` : ''}`);
  const when = a.last_success ? `last confirmed ${ago(a.last_success)}`
    : (a.modified ? `file changed ${ago(a.modified)}` : 'not checked yet');
  $('anchor-status').textContent = keys.length
    ? `Root keys ${keys.join(', ')} · ${when}`
    : 'No root key found. Use "Reset to built-in".';
}

function showError(msg) {
  const e = $('apply-error');
  e.textContent = msg;
  e.hidden = false;
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

async function load() {
  loaded = await ctlJson('settings');
  writeForm(loaded.settings);
  $('forwarders').value = forwardersToText(loaded.forwarders);
  renderAnchor(loaded.anchor);
  refreshUi();
}

// Run a slow action behind a full-screen "busy" note; one at a time.
let running = false;
async function busy(text, fn) {
  if (running) return undefined;
  running = true;
  $('busy-text').textContent = text;
  $('busy').hidden = false;
  try {
    return await fn();
  } finally {
    $('busy').hidden = true;
    running = false;
  }
}

// Run a ctl.sh action that answers with {ok, ...} behind the busy overlay,
// re-read the settings before the overlay goes away (so nothing the user
// types afterwards gets overwritten), then report the result.
async function act(text, args, okText) {
  $('apply-error').hidden = true;
  let r;
  try {
    r = await busy(text, async () => {
      try {
        return await ctlResult(...args);
      } finally {
        await load().catch(() => {});
      }
    });
  } catch (e) {
    showError(e.message);
    return false;
  }
  if (r === undefined) return false;
  if (r.ok) toast(typeof okText === 'function' ? okText(r) : okText);
  else showError(r.error || 'Not applied.');
  return r.ok;
}

async function apply() {
  const c = changes();
  if (!c.length) return;
  await act('Applying… Unbound is restarting', ['settings-apply', ...c],
    (r) => (r.applied ? 'Applied' : 'Saved; used when Unbound starts'));
}

async function loadCustom() {
  try {
    $('custom-conf').value = await ctl('custom-get');
  } catch (e) {
    toast(e.message, true);
  }
}

async function saveCustom() {
  const text = $('custom-conf').value || '\n';
  const b64 = btoa(unescape(encodeURIComponent(text)));
  await act('Saving custom.conf… Unbound is restarting', ['custom-set', b64],
    (r) => (r.applied ? 'custom.conf applied' : 'custom.conf saved'));
  await loadCustom(); // after a failure this shows the restored file
}

function init() {
  form.addEventListener('input', refreshUi);
  form.addEventListener('change', refreshUi);
  form.addEventListener('submit', (e) => e.preventDefault());
  $('apply-btn').addEventListener('click', apply);
  $('discard-btn').addEventListener('click', () => {
    writeForm(loaded.settings);
    $('forwarders').value = forwardersToText(loaded.forwarders);
    refreshUi();
  });
  $('anchor-update').addEventListener('click', () => act('Checking the trust anchor with IANA…',
    ['anchor-update'], (r) => (r.changed === false ? 'The trust anchor is up to date' : 'Trust anchor updated')));
  $('anchor-reset-slot').replaceWith(confirmButton('Reset to built-in',
    () => act('Restoring the built-in trust anchor…', ['anchor-reset'], 'Built-in trust anchor restored'),
    { class: 'btn', text: 'Reset to built-in', armedText: 'Tap again to reset' }));
  $('defaults-slot').replaceWith(confirmButton('Restore all defaults',
    () => act('Restoring defaults… Unbound is restarting', ['settings-reset'], 'All settings are back to their defaults'),
    { class: 'btn', text: 'Restore all defaults', armedText: 'Tap again to restore' }));
  $('advanced').addEventListener('toggle', (e) => { if (e.target.open) loadCustom(); });
  $('custom-save').addEventListener('click', saveCustom);
  load().catch((e) => showError(e.message));
}

init();
