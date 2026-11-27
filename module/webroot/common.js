'use strict';

// Shared by index.html and settings.html. Everything goes through the
// module's control script. Arguments are always single-quoted for the shell;
// ctl.sh validates them again.
const CTL = 'sh /data/adb/modules/unbound-dns/ctl.sh';

const $ = (id) => document.getElementById(id);
const nf = new Intl.NumberFormat();
let cbSeq = 0;

function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }

function exec(cmd) {
  return new Promise((resolve, reject) => {
    if (typeof window.ksu === 'undefined' || typeof window.ksu.exec !== 'function') {
      reject(new Error('Open this page from the KernelSU manager.'));
      return;
    }
    const cb = `__unboundCb${Date.now()}_${cbSeq++}`;
    window[cb] = (errno, stdout, stderr) => {
      delete window[cb];
      resolve({ errno, stdout: stdout || '', stderr: stderr || '' });
    };
    try {
      window.ksu.exec(cmd, '{}', cb);
    } catch (e) {
      delete window[cb];
      reject(e);
    }
  });
}

function errorText(r) {
  const msg = (r.stderr || r.stdout || 'Command failed').trim().split('\n').pop();
  return msg.replace(/^error:\s*/, '');
}

async function ctl(...args) {
  const r = await exec(`${CTL} ${args.map(shq).join(' ')}`);
  if (r.errno !== 0) throw new Error(errorText(r));
  return r.stdout.trim();
}

async function ctlJson(...args) { return JSON.parse(await ctl(...args)); }

// For commands that answer with a JSON result even when they fail
// (settings-apply, custom-set, anchor-*): returns {ok, ...} or throws on
// a validation error that produced no JSON.
async function ctlResult(...args) {
  const r = await exec(`${CTL} ${args.map(shq).join(' ')}`);
  const last = r.stdout.trim().split('\n').pop();
  try {
    return JSON.parse(last);
  } catch {
    throw new Error(errorText(r));
  }
}

// Icons from Material Icons (Apache License 2.0,
// https://github.com/google/material-design-icons), drawn inline.
const ICONS = {
  close: 'M19 6.41 17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z',
};
function icon(name) {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('class', 'icon');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  const p = document.createElementNS(ns, 'path');
  p.setAttribute('d', ICONS[name]);
  svg.append(p);
  return svg;
}

// The top app bar takes a container colour once the page scrolls under it.
addEventListener('scroll', () => {
  document.body.classList.toggle('scrolled', scrollY > 0);
}, { passive: true });

let toastTimer = null;
function toast(msg, bad = false) {
  const t = $('toast');
  t.textContent = msg;
  t.className = bad ? 'toast bad' : 'toast';
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, bad ? 6000 : 2500);
}

function el(tag, props = {}, ...children) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === 'class') e.className = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (v !== undefined && v !== null && v !== false) e.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children) if (c !== null && c !== undefined) e.append(c);
  return e;
}

function ago(ts) {
  if (!ts) return 'never';
  const s = Math.max(0, Math.floor(Date.now() / 1000) - ts);
  if (s < 90) return 'just now';
  if (s < 5400) return `${Math.round(s / 60)} min ago`;
  if (s < 129600) return `${Math.round(s / 3600)} h ago`;
  return `${Math.round(s / 86400)} days ago`;
}

// WebView may not show confirm() dialogs, so ask in place: first tap arms
// the button, a second tap within 4 s does it.
function confirmButton(label, onConfirm, opts = {}) {
  const idle = () => opts.text || icon('close');
  const armed = opts.armedText || 'Remove?';
  const b = el('button', { type: 'button', class: opts.class || 'icon-btn', 'aria-label': label, title: label }, idle());
  let timer = null;
  const reset = () => { b.replaceChildren(idle()); b.classList.remove('armed'); };
  b.addEventListener('click', () => {
    if (timer) {
      clearTimeout(timer);
      timer = null;
      reset();
      onConfirm();
      return;
    }
    b.textContent = armed;
    b.classList.add('armed');
    timer = setTimeout(() => { timer = null; reset(); }, 4000);
  });
  return b;
}
