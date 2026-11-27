'use strict';

const PRESETS = [
  { name: 'OISD small', url: 'https://small.oisd.nl/',
    note: 'Ads and trackers, tuned to almost never break anything.' },
  { name: 'OISD big', url: 'https://big.oisd.nl/',
    note: 'Ads, trackers and malware. Still very few false positives.' },
  { name: 'HaGeZi Light', url: 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/light.txt',
    note: 'Small and gentle.' },
  { name: 'HaGeZi Normal', url: 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/multi.txt',
    note: 'Ads, trackers, malware. A good default.' },
  { name: 'HaGeZi Pro', url: 'https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.txt',
    note: 'Stricter; may block the odd site or app feature.' },
  { name: 'StevenBlack hosts', url: 'https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts',
    note: 'Classic unified hosts file.' },
];

let state = { status: null, lists: null, logKind: 'module', busy: false };

function duration(s) {
  if (!s) return '—';
  if (s < 3600) return `${Math.floor(s / 60)} min`;
  if (s < 172800) return `${Math.floor(s / 3600)} h`;
  return `${Math.floor(s / 86400)} days`;
}

function mem(kb) {
  if (!kb) return '—';
  return kb > 10240 ? `${Math.round(kb / 1024)} MB` : `${(kb / 1024).toFixed(1)} MB`;
}

// --- status -------------------------------------------------------------------

function renderStatus(s) {
  const dot = $('status-dot');
  const text = $('status-text');
  const btn = $('redirect-btn');
  $('module-version').textContent = s.module_version || '';

  if (!s.running) {
    dot.className = 'dot bad';
    text.textContent = s.daemon ? 'Starting… / not running' : 'Not running';
    $('status-sub').textContent = 'Apps use the network\'s DNS while Unbound is down.';
  } else if (s.redirect_active) {
    dot.className = 'dot ok';
    text.textContent = 'Protecting all DNS';
    $('status-sub').textContent = `Every app's DNS goes to Unbound on this phone. Resolver: ${s.resolver_label || 'Recursive'}.`;
  } else {
    dot.className = 'dot warn';
    text.textContent = 'Redirect off';
    $('status-sub').textContent = s.redirect_enabled
      ? 'Unbound is running; applying the redirect…'
      : 'Unbound is running, but apps use the network\'s DNS. Turn it back on after signing in to Wi-Fi.';
  }
  btn.disabled = false;
  btn.textContent = s.redirect_enabled ? 'Turn off' : 'Turn on';
  btn.classList.toggle('primary', !s.redirect_enabled);

  const hit = s.queries ? Math.round((100 * s.cache_hits) / s.queries) : 0;
  const stats = $('stats');
  stats.replaceChildren(
    ...[
      ['Queries', nf.format(s.queries || 0)],
      ['From cache', s.queries ? `${hit}%` : '—'],
      ['Memory', mem(s.memory_kb)],
      ['Uptime', duration(s.uptime)],
      ['IPv6 DNS', !s.redirect_active ? '—'
        : ({ ok: 'Redirected', unsupported: 'Not redirected' }[s.ipv6] || '—')],
      ['Unbound', s.version || '—'],
      ['SELinux', {
        learning: 'Own domain (learning)', enforcing: 'Own domain',
        fallback: 'Manager\'s (fell back)', unconfined: 'Manager\'s',
      }[s.selinux] || '—'],
    ].map(([k, v]) => el('div', {}, el('dt', {}, k), el('dd', {}, v))),
  );

  $('stats-since').textContent = s.stats_since
    ? `Counted since ${new Date(s.stats_since * 1000).toLocaleDateString()} ·` : '';

  const w = [];
  if (s.error && !s.running) w.push(['bad', `Unbound failed to start: ${s.error}`]);
  if (s.running && s.private_dns && s.private_dns !== 'off' && s.private_dns !== 'null')
    w.push(['warn', 'Private DNS is on in Android settings, so DNS bypasses Unbound. Set it to Off.']);
  if (s.redirect_active && s.ipv6 === 'unsupported')
    w.push(['warn', 'This kernel cannot redirect IPv6 DNS, so IPv6 DNS servers are used directly.']);
  if (s.blocked > 500000)
    w.push(['warn', `${nf.format(s.blocked)} blocked domains use a lot of memory (about ${Math.round(s.blocked * 0.4 / 1024)} MB). Consider fewer or smaller lists.`]);
  $('warnings').replaceChildren(...w.map(([k, m]) => el('p', { class: `notice ${k}` }, m)));

  $('blocked-total').textContent = `${nf.format(s.blocked || 0)} domains`;
  const refresh = $('refresh');
  if (document.activeElement !== refresh) refresh.value = String(s.refresh_hours || 24);

  const us = $('update-status');
  const upd = $('update-btn');
  if (s.updating) {
    us.textContent = 'Updating blocklists…';
    upd.disabled = true;
  } else {
    upd.disabled = false;
    us.textContent = s.last_update
      ? `Last update ${ago(s.last_update)}${s.last_update_ok ? '' : ' (some lists failed)'}`
      : '';
  }
}

async function refreshStatus() {
  try {
    const s = await ctlJson('status');
    const prev = state.status;
    state.status = s;
    renderStatus(s);
    // A list update finished. Compare the finish time, not just the
    // "updating" flag: a quick update can start and end between two polls.
    if (prev && !s.updating && (prev.updating || prev.last_update !== s.last_update)) refreshLists();
  } catch (e) {
    $('status-dot').className = 'dot bad';
    $('status-text').textContent = 'Cannot reach the module';
    $('status-sub').textContent = e.message;
  }
}

// --- lists --------------------------------------------------------------------

function sourceItem(src) {
  const sw = el('input', { type: 'checkbox', 'aria-label': `Enable ${src.name}` });
  sw.checked = !!src.enabled;
  sw.addEventListener('change', () => act(
    () => ctl('list-enable', src.id, sw.checked ? '1' : '0'),
    sw.checked ? `${src.name} enabled` : `${src.name} disabled`,
  ));
  let sub;
  if (src.status === 'error') {
    sub = el('div', { class: 'item-sub bad' }, `Update failed: ${src.message || 'unknown error'}`
      + (src.count ? ` · using last copy (${nf.format(src.count)})` : ''));
  } else if (src.updated) {
    sub = el('div', { class: 'item-sub' }, `${nf.format(src.count)} domains · updated ${ago(src.updated)}`);
  } else {
    sub = el('div', { class: 'item-sub' }, 'Not downloaded yet');
  }
  return el('li', {},
    el('label', { class: 'switch' }, sw, el('span')),
    el('div', { class: 'item-main' },
      el('div', { class: 'item-title' }, src.name),
      sub,
      el('div', { class: 'item-sub' }, src.url)),
    confirmButton(`Remove ${src.name}`, () => act(() => ctl('list-remove', src.id), `${src.name} removed`)));
}

function renderLists(l) {
  const items = [
    ...l.sources.map(sourceItem),
    ...l.local.map((f) => el('li', {},
      el('div', { class: 'item-main' },
        el('div', { class: 'item-title' }, f.file),
        el('div', { class: 'item-sub' }, `${nf.format(f.count)} domains · local file in ${l.local_dir}`)))),
  ];
  $('sources').replaceChildren(...items);
  $('sources-empty').hidden = items.length > 0;

  $('allow').replaceChildren(...l.allow.map((d) => el('li', {},
    el('div', { class: 'item-main' }, el('div', { class: 'item-title' }, d)),
    el('button', {
      type: 'button', class: 'icon-btn', 'aria-label': `Remove ${d} from allowlist`, title: 'Remove',
      onclick: () => act(() => ctl('allow-remove', d), `${d} removed from allowlist`),
    }, icon('close')))));

  $('own').replaceChildren(...(l.block || []).map((d) => el('li', {},
    el('div', { class: 'item-main' }, el('div', { class: 'item-title' }, d)),
    el('button', {
      type: 'button', class: 'icon-btn', 'aria-label': `Remove ${d} from my blocklist`, title: 'Remove',
      onclick: () => act(() => ctl('block-remove', d), `${d} is no longer blocked by you`),
    }, icon('close')))));

  const have = new Set(l.sources.map((s) => s.url));
  const sel = $('preset');
  const keep = sel.value;
  sel.replaceChildren(
    ...PRESETS.filter((p) => !have.has(p.url)).map((p) => el('option', { value: p.url }, p.name)),
    el('option', { value: 'custom' }, 'Custom URL…'),
  );
  if ([...sel.options].some((o) => o.value === keep)) sel.value = keep;
  onPresetChange();
}

async function refreshLists() {
  try {
    state.lists = await ctlJson('lists');
    renderLists(state.lists);
  } catch (e) {
    toast(e.message, true);
  }
}

// Run an action, then refresh everything. One at a time.
async function act(fn, okMsg) {
  if (state.busy) return;
  state.busy = true;
  document.body.classList.add('busy');
  try {
    await fn();
    if (okMsg) toast(okMsg);
  } catch (e) {
    toast(e.message, true);
  } finally {
    state.busy = false;
    document.body.classList.remove('busy');
    await Promise.all([refreshLists(), refreshStatus()]);
  }
}

function onPresetChange() {
  const v = $('preset').value;
  const custom = v === 'custom';
  $('custom-fields').hidden = !custom;
  const p = PRESETS.find((x) => x.url === v);
  $('preset-note').textContent = p ? p.note : (custom ? 'Any https list in hosts, domain, adblock or dnsmasq format.' : '');
}

async function addList(ev) {
  ev.preventDefault();
  const v = $('preset').value;
  let url;
  let name;
  if (v === 'custom') {
    url = $('custom-url').value.trim();
    name = $('custom-name').value.trim();
    if (!/^https:\/\//i.test(url)) { toast('Only https:// lists are supported.', true); return; }
  } else {
    const p = PRESETS.find((x) => x.url === v);
    if (!p) return;
    url = p.url;
    name = p.name;
  }
  await act(async () => {
    const args = ['list-add', url];
    if (name) args.push(name);
    await ctl(...args);
    await ctl('update-lists', '--bg');
    $('custom-url').value = '';
    $('custom-name').value = '';
  }, `Added ${name || url}; downloading…`);
}

async function addOwnBlock(ev) {
  ev.preventDefault();
  const input = $('own-input');
  const d = input.value.trim().replace(/^https?:\/\//i, '').replace(/\/.*$/, '');
  if (!d) return;
  await act(async () => {
    await ctl('block-add', d);
    input.value = '';
  }, `${d.replace(/^\*\./, '')} and its subdomains are blocked`);
}

async function addAllow(ev) {
  ev.preventDefault();
  const input = $('allow-input');
  const d = input.value.trim().replace(/^https?:\/\//i, '').replace(/\/.*$/, '');
  if (!d) return;
  await act(async () => {
    await ctl('allow-add', d);
    input.value = '';
  }, `${d} will not be blocked`);
}

// --- log ------------------------------------------------------------------------

async function refreshLog() {
  try {
    const out = state.logKind === 'diag' ? await ctl('diag') : await ctl('log', state.logKind, '300');
    const pre = $('log');
    pre.textContent = out || '(empty)';
    pre.scrollTop = pre.scrollHeight;
  } catch (e) {
    $('log').textContent = e.message;
  }
}

// --- wiring -----------------------------------------------------------------------

function init() {
  $('redirect-btn').addEventListener('click', () => {
    const on = !(state.status && state.status.redirect_enabled);
    act(() => ctl('redirect', on ? 'on' : 'off'), on ? 'Redirect on' : 'Redirect off: apps use the network\'s DNS');
  });
  $('preset').addEventListener('change', onPresetChange);
  $('add-form').addEventListener('submit', addList);
  $('allow-form').addEventListener('submit', addAllow);
  $('own-form').addEventListener('submit', addOwnBlock);
  $('stats-reset-slot').replaceWith(confirmButton('Reset statistics',
    () => act(() => ctl('stats-reset'), 'Statistics reset'),
    { class: 'link-btn', text: 'Reset', armedText: 'Tap again to reset' }));
  $('update-btn').addEventListener('click', () => act(() => ctl('update-lists', '--force', '--bg'), 'Updating all lists…'));
  $('refresh').addEventListener('change', (e) => act(() => ctl('set', 'refresh_hours', e.target.value), 'Refresh interval saved'));
  $('log-details').addEventListener('toggle', (e) => { if (e.target.open) refreshLog(); });
  $('log-refresh').addEventListener('click', refreshLog);
  $('log-copy').addEventListener('click', async () => {
    const text = $('log').textContent;
    try {
      await navigator.clipboard.writeText(text);
      toast('Copied');
    } catch {
      // Older WebViews: select the text so it can be copied by hand.
      const r = document.createRange();
      r.selectNodeContents($('log'));
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(r);
      toast('Selected; long-press to copy');
    }
  });
  for (const b of document.querySelectorAll('[data-log]')) {
    b.addEventListener('click', () => {
      state.logKind = b.dataset.log;
      for (const o of document.querySelectorAll('[data-log]')) {
        o.classList.toggle('active', o === b);
        o.setAttribute('aria-selected', String(o === b));
      }
      refreshLog();
    });
  }

  refreshStatus();
  refreshLists();
  setInterval(() => { if (!document.hidden && !state.busy) refreshStatus(); }, 3000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshStatus(); });
}

init();
