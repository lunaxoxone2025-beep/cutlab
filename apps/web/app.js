'use strict';
/* =============================================================
   CutLab — editor de vídeo estilo CapCut en el navegador.
   Todo se procesa en tu dispositivo: nada se sube a internet.
   ============================================================= */

// ---------- utilidades ----------
const $ = (s, r = document) => r.querySelector(s);
const uid = () => Math.random().toString(36).slice(2, 10);
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const ease = t => 1 - Math.pow(1 - clamp(t, 0, 1), 3);
const backOut = t => { t = clamp(t, 0, 1) - 1; return 1 + 2.70158 * t * t * t + 1.70158 * t * t; };
const fmt = t => {
  t = Math.max(0, t || 0);
  const m = Math.floor(t / 60), s = Math.floor(t % 60), d = Math.floor((t * 10) % 10);
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}.${d}`;
};
const fmtTick = s => `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
function h(tag, props = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'style') el.style.cssText = v;
    else if (k === 'html') el.innerHTML = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    el.append(kid.nodeType ? kid : document.createTextNode(kid));
  }
  return el;
}
function hexA(hex, a) {
  const n = parseInt((hex || '#000000').slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}
let toastTimer = 0;
function toast(msg) {
  const t = $('#toast'); t.textContent = msg; t.classList.add('show');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.remove('show'), 2400);
}

// ---------- iconos ----------
const ICONS = {
  plus: '<path d="M12 5v14M5 12h14"/>',
  minus: '<path d="M5 12h14"/>',
  text: '<path d="M5 7V5h14v2M9 19h6M12 5v14"/>',
  music: '<path d="M9 18V5l11-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="17" cy="16" r="3"/>',
  ratio: '<rect x="6" y="3" width="12" height="18" rx="2"/><path d="M10 7h4"/>',
  bg: '<rect x="3" y="3" width="18" height="18" rx="3"/><path d="M3 15l5-5 4 4 3-3 6 6"/>',
  split: '<path d="M12 3v18M7 7l-4 5 4 5M17 7l4 5-4 5"/>',
  trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
  copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>',
  speed: '<path d="M12 14l4-5"/><path d="M3.5 18a9 9 0 1 1 17 0"/><circle cx="12" cy="14" r="1"/>',
  volume: '<path d="M11 5L6 9H3v6h3l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/>',
  filter: '<circle cx="9" cy="9" r="6"/><circle cx="15" cy="15" r="6"/>',
  adjust: '<path d="M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1"/><circle cx="15" cy="6" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="17" cy="18" r="2"/>',
  trans: '<path d="M4 6l8 6-8 6zM20 6l-8 6 8 6z"/>',
  motion: '<path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7"/>',
  crop: '<path d="M6 2v14a2 2 0 0 0 2 2h14M2 6h14a2 2 0 0 1 2 2v14"/>',
  left: '<path d="M15 6l-6 6 6 6"/>',
  right: '<path d="M9 6l6 6-6 6"/>',
  back: '<path d="M19 12H5M11 6l-6 6 6 6"/>',
  edit: '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="M13 7l4 4"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  undo: '<path d="M9 14L4 9l5-5"/><path d="M4 9h11a5 5 0 0 1 0 10h-3"/>',
  redo: '<path d="M15 14l5-5-5-5"/><path d="M20 9H9a5 5 0 0 0 0 10h3"/>',
  play: '<path d="M7 4.5l12.5 7.5L7 19.5z" fill="currentColor"/>',
  pause: '<rect x="6" y="4.5" width="4" height="15" rx="1" fill="currentColor"/><rect x="14" y="4.5" width="4" height="15" rx="1" fill="currentColor"/>',
  dots: '<circle cx="5" cy="12" r="1.6" fill="currentColor"/><circle cx="12" cy="12" r="1.6" fill="currentColor"/><circle cx="19" cy="12" r="1.6" fill="currentColor"/>',
  check: '<path d="M5 12.5l4.5 4.5L19 7"/>',
  rotate: '<path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/>',
  flip: '<path d="M12 3v18M8 7l-5 5 5 5zM16 7l5 5-5 5z"/>',
  fade: '<path d="M3 18L9 6h6l6 12"/>',
  new: '<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6M12 12v6M9 15h6"/>',
  help: '<circle cx="12" cy="12" r="9"/><path d="M9.5 9a2.5 2.5 0 1 1 3.5 2.3c-.7.3-1 .9-1 1.7M12 17h.01"/>',
  download: '<path d="M12 4v11M7 10l5 5 5-5M5 20h14"/>',
  install: '<rect x="6" y="2" width="12" height="20" rx="2"/><path d="M12 7v7M9 11l3 3 3-3"/>',
};
const ic = n => `<svg viewBox="0 0 24 24" aria-hidden="true">${ICONS[n] || ''}</svg>`;

// ---------- catálogos ----------
const RATIOS = { '9:16': [9, 16], '16:9': [16, 9], '1:1': [1, 1], '4:5': [4, 5], '3:4': [3, 4] };
function dims(ratio, short = 720) {
  const [a, b] = RATIOS[ratio] || RATIOS['9:16'];
  const even = v => Math.round(v / 2) * 2;
  return a <= b ? [short, even(short * b / a)] : [even(short * a / b), short];
}
const FILTERS = {
  none: { n: 'Original', f: '' },
  vivid: { n: 'Vívido', f: 'saturate(1.45) contrast(1.08)' },
  warm: { n: 'Cálido', f: 'sepia(.22) saturate(1.3) brightness(1.03)' },
  cool: { n: 'Frío', f: 'hue-rotate(-12deg) saturate(1.1) contrast(1.05)' },
  vintage: { n: 'Vintage', f: 'sepia(.45) contrast(.92) brightness(1.06) saturate(.85)' },
  fade: { n: 'Suave', f: 'contrast(.82) brightness(1.12) saturate(.75)' },
  drama: { n: 'Drama', f: 'contrast(1.4) brightness(.92) saturate(1.1)' },
  dream: { n: 'Sueño', f: 'saturate(1.25) brightness(1.1) contrast(.9) hue-rotate(8deg)' },
  bw: { n: 'B/N', f: 'grayscale(1) contrast(1.1)' },
  noir: { n: 'Noir', f: 'grayscale(1) contrast(1.6) brightness(.85)' },
};
const TRANSITIONS = [
  { v: 'none', n: 'Ninguna' }, { v: 'fade', n: 'Fundido' }, { v: 'black', n: 'A negro' },
  { v: 'flash', n: 'Destello' }, { v: 'zoom', n: 'Zoom' }, { v: 'slideL', n: 'Deslizar' },
  { v: 'slideU', n: 'Subir' }, { v: 'blur', n: 'Desenfoque' },
];
const OVERLAP_TRANS = ['fade', 'zoom', 'slideL', 'slideU', 'blur'];
const MOTIONS = [
  { v: 'none', n: 'Ninguno' }, { v: 'zoomIn', n: 'Acercar' }, { v: 'zoomOut', n: 'Alejar' },
  { v: 'panL', n: 'Paneo ←' }, { v: 'panR', n: 'Paneo →' },
];
const FONTS = [
  { id: 'Inter', n: 'Moderna', w: 800 }, { id: 'Bebas Neue', n: 'Impacto', w: 400 },
  { id: 'Pacifico', n: 'Script', w: 400 }, { id: 'Permanent Marker', n: 'Marcador', w: 400 },
  { id: 'Playfair Display', n: 'Elegante', w: 700 }, { id: 'Space Mono', n: 'Mono', w: 700 },
];
const COLORS = ['#ffffff', '#000000', '#ffde2e', '#ff3b5c', '#ff8a00', '#19e3c4', '#3fa3ff', '#8f5cff', '#ff7ad9', '#7cff4f'];
const ANIM_IN = [{ v: 'none', n: 'Ninguna' }, { v: 'fade', n: 'Aparecer' }, { v: 'pop', n: 'Pop' }, { v: 'slide', n: 'Subir' }, { v: 'zoom', n: 'Zoom' }, { v: 'type', n: 'Máquina' }];
const ANIM_OUT = [{ v: 'none', n: 'Ninguna' }, { v: 'fade', n: 'Desvanecer' }, { v: 'pop', n: 'Encoger' }, { v: 'slide', n: 'Subir' }];
const TEXT_BASE = { text: 'Tu texto', font: 'Inter', size: 72, color: '#ffffff', stroke: true, strokeColor: '#000000', strokeW: 5, bg: false, bgColor: '#000000', bgAlpha: .6, shadow: 'drop', x: .5, y: .5, animIn: 'pop', animOut: 'fade' };
const TEMPLATES = [
  { n: 'Básico', s: {} },
  { n: 'Subtítulo', s: { text: 'Subtítulo aquí', size: 52, y: .8, shadow: 'none', animIn: 'fade' } },
  { n: 'Título', s: { text: 'GRAN TÍTULO', font: 'Bebas Neue', size: 150, color: '#ffde2e', stroke: false, y: .3, animIn: 'zoom' } },
  { n: 'Caja', s: { text: 'Texto en caja', size: 58, stroke: false, bg: true, bgColor: '#000000', bgAlpha: .7, shadow: 'none', animIn: 'slide' } },
  { n: 'Neón', s: { text: 'Neón', font: 'Pacifico', size: 110, color: '#ff7ad9', stroke: false, shadow: 'glow' } },
  { n: 'Marcador', s: { text: '¡WOW!', font: 'Permanent Marker', size: 100, color: '#111111', stroke: false, bg: true, bgColor: '#ffde2e', bgAlpha: 1, shadow: 'none' } },
  { n: 'Elegante', s: { text: 'Momentos', font: 'Playfair Display', size: 96, stroke: false, shadow: 'drop', animIn: 'fade' } },
  { n: 'Máquina', s: { text: 'escribiendo...', font: 'Space Mono', size: 60, color: '#19e3c4', stroke: false, bg: true, bgColor: '#000000', bgAlpha: .8, shadow: 'none', animIn: 'type' } },
];

// ---------- almacenamiento (IndexedDB) ----------
const DB = (() => {
  let p;
  const open = () => p || (p = new Promise((res, rej) => {
    const r = indexedDB.open('cutlab', 1);
    r.onupgradeneeded = () => { const d = r.result; d.createObjectStore('media', { keyPath: 'id' }); d.createObjectStore('kv'); };
    r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
  }));
  const run = async (store, mode, fn) => {
    const d = await open();
    return new Promise((res, rej) => {
      const t = d.transaction(store, mode); const req = fn(t.objectStore(store));
      t.oncomplete = () => res(req && req.result); t.onerror = () => rej(t.error); t.onabort = () => rej(t.error);
    });
  };
  return {
    put: (s, v, k) => run(s, 'readwrite', o => (k === undefined ? o.put(v) : o.put(v, k))),
    get: (s, k) => run(s, 'readonly', o => o.get(k)),
    clear: s => run(s, 'readwrite', o => o.clear()),
  };
})();

// ---------- estado ----------
const newProject = () => ({ v: 1, ratio: '9:16', bg: 'blur', main: [], texts: [], audios: [] });
let project = newProject();
const media = new Map();     // id -> {id,type,name,blob,url,duration,w,h,thumb,wave}
const els = new Map();       // clipId -> elemento <video>/<audio>/<img>
const textBoxes = new Map(); // textId -> caja en el lienzo (para tocar/arrastrar)
let sel = null;              // {id, type: 'main'|'text'|'audio'}
let curT = 0, playing = false, lastTs = 0, dirty = true, previewT = null, stalled = false, stallStart = 0;
let pps = 60;                // píxeles por segundo en la línea de tiempo
let exporting = false, dragActive = false;
let actx = null, master = null, recDest = null;
let hist = [], hIdx = -1, saveTimer = 0;

const cv = $('#cv'), ctx = cv.getContext('2d');
const small = document.createElement('canvas'), sctx = small.getContext('2d');
const tl = $('#tl'), tlInner = $('#tlInner'), ruler = $('#ruler');
const rowMain = $('#rowMain'), rowText = $('#rowText'), rowAudio = $('#rowAudio');
const pool = $('#pool');

const clipDur = c => (c.out - c.in) / c.speed;
const audDur = a => a.out - a.in;
function mainSeq() {
  let t = 0;
  return project.main.map(c => { const d = clipDur(c); const e = { c, start: t, end: t + d }; t += d; return e; });
}
function totalDur() {
  const seq = mainSeq(); let T = seq.length ? seq[seq.length - 1].end : 0;
  for (const x of project.texts) T = Math.max(T, x.start + x.dur);
  for (const a of project.audios) T = Math.max(T, a.start + audDur(a));
  return T;
}
function findClip(id) {
  for (const [type, arr] of [['main', project.main], ['text', project.texts], ['audio', project.audios]]) {
    const c = arr.find(x => x.id === id); if (c) return { c, type, arr };
  }
  return null;
}
const isSel = id => sel && sel.id === id;
const markDirty = () => { dirty = true; };

// ---------- historial y guardado ----------
function commit() {
  const s = JSON.stringify(project);
  if (hist[hIdx] !== s) {
    hist = hist.slice(0, hIdx + 1); hist.push(s);
    if (hist.length > 80) hist.shift();
    hIdx = hist.length - 1;
    scheduleSave();
  }
  afterChange();
}
function afterChange() {
  if (sel && !findClip(sel.id)) { sel = null; buildToolbar(); }
  pruneEls(); buildTimeline(); markDirty(); updateUndo(); updateEmpty();
}
function undo() { if (hIdx > 0) { hIdx--; restoreHist(); } }
function redo() { if (hIdx < hist.length - 1) { hIdx++; restoreHist(); } }
function restoreHist() {
  const r = project.ratio; project = JSON.parse(hist[hIdx]);
  if (r !== project.ratio) resizeCanvas();
  closeSheet(false); scheduleSave(); afterChange(); buildToolbar();
}
function updateUndo() { $('#btnUndo').disabled = hIdx <= 0; $('#btnRedo').disabled = hIdx >= hist.length - 1; }
function scheduleSave() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => DB.put('kv', project, 'project').catch(() => {}), 500);
}
function updateEmpty() { $('#empty').classList.toggle('hidden', project.main.length + project.texts.length + project.audios.length > 0); }

// ---------- medios ----------
function loadImg(url) {
  return new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = rej; i.src = url; });
}
function loadVideo(url) {
  return new Promise((res, rej) => {
    const v = document.createElement('video');
    v.muted = true; v.playsInline = true; v.preload = 'auto';
    let done = false;
    const finish = ok => { if (done) return; done = true; clearTimeout(to); ok ? res(v) : rej(new Error('video')); };
    const to = setTimeout(() => finish(v.duration > 0 && isFinite(v.duration)), 15000);
    v.onerror = () => finish(false);
    v.onloadedmetadata = async () => {
      if (!isFinite(v.duration)) { // vídeos grabados en el navegador a veces no traen duración
        await new Promise(r => { v.ondurationchange = () => isFinite(v.duration) && r(); v.currentTime = 1e7; setTimeout(r, 4000); });
        v.ondurationchange = null;
        if (!isFinite(v.duration)) return finish(false);
      }
      v.onseeked = () => finish(true);
      v.currentTime = Math.min(0.5, v.duration / 3);
    };
    v.src = url;
  });
}
function audioDuration(url) {
  return new Promise((res, rej) => {
    const a = new Audio(); a.preload = 'metadata';
    a.onloadedmetadata = () => {
      if (isFinite(a.duration)) return res(a.duration);
      a.ondurationchange = () => isFinite(a.duration) && res(a.duration); a.currentTime = 1e7;
    };
    a.onerror = rej; a.src = url; setTimeout(() => rej(new Error('timeout')), 15000);
  });
}
function snapThumb(src, w, h) {
  try {
    const H = 96, W = clamp(Math.round(H * w / h), 40, 220);
    const c = document.createElement('canvas'); c.width = W; c.height = H;
    const x = c.getContext('2d'); const s = Math.max(W / w, H / h);
    x.drawImage(src, (W - w * s) / 2, (H - h * s) / 2, w * s, h * s);
    return c.toDataURL('image/jpeg', .72);
  } catch { return ''; }
}
async function waveform(blob) {
  const AC = window.OfflineAudioContext || window.webkitOfflineAudioContext;
  const oc = new AC(1, 44100, 44100);
  const buf = await oc.decodeAudioData(await blob.arrayBuffer());
  const d = buf.getChannelData(0), N = 500, step = Math.max(1, Math.floor(d.length / N));
  const c = document.createElement('canvas'); c.width = N * 2; c.height = 56;
  const x = c.getContext('2d'); x.fillStyle = 'rgba(255,255,255,.45)';
  for (let i = 0; i < N; i++) {
    let mx = 0;
    for (let j = i * step; j < (i + 1) * step && j < d.length; j += 16) { const v = Math.abs(d[j]); if (v > mx) mx = v; }
    const hh = Math.max(1, Math.min(1, mx * 1.2) * 52); x.fillRect(i * 2, (56 - hh) / 2, 1.3, hh);
  }
  return c.toDataURL();
}
function typeOf(blob, name) {
  const t = (blob.type || '').split('/')[0];
  if (['video', 'image', 'audio'].includes(t)) return t;
  const ext = (name.split('.').pop() || '').toLowerCase();
  if (/^(mp4|mov|webm|mkv|m4v|3gp|avi)$/.test(ext)) return 'video';
  if (/^(jpe?g|png|gif|webp|bmp|avif|heic)$/.test(ext)) return 'image';
  if (/^(mp3|wav|ogg|oga|m4a|aac|flac|opus|weba)$/.test(ext)) return 'audio';
  return '';
}
async function makeMedia(blob, name) {
  const type = typeOf(blob, name); if (!type) throw new Error('tipo');
  const url = URL.createObjectURL(blob);
  const m = { id: uid(), type, name, blob, url, duration: 0, w: 0, h: 0, thumb: '', wave: '' };
  try {
    if (type === 'image') {
      const img = await loadImg(url); m.w = img.naturalWidth; m.h = img.naturalHeight; m.duration = 3600; m.thumb = snapThumb(img, m.w, m.h);
    } else if (type === 'video') {
      const v = await loadVideo(url); m.w = v.videoWidth; m.h = v.videoHeight; m.duration = v.duration; m.thumb = snapThumb(v, m.w, m.h);
      v.removeAttribute('src'); v.load();
    } else {
      m.duration = await audioDuration(url); m.wave = await waveform(blob).catch(() => '');
    }
  } catch (e) { URL.revokeObjectURL(url); throw e; }
  if (!(m.duration > 0)) throw new Error('duración');
  return m;
}
async function importFiles(files, forceAudio = false) {
  files = [...files]; if (!files.length) return;
  toast(files.length > 1 ? `Importando ${files.length} archivos…` : 'Importando…');
  let added = 0, firstNew = null;
  for (const f of files) {
    try {
      const m = await makeMedia(f, f.name || 'archivo');
      media.set(m.id, m);
      const { url, ...rec } = m; DB.put('media', rec).catch(() => {});
      if (m.type === 'audio' || forceAudio) {
        if (m.type === 'image') continue;
        const a = { id: uid(), mediaId: m.id, start: curT, in: 0, out: m.duration, volume: 1, fadeIn: 0, fadeOut: 0 };
        project.audios.push(a); firstNew = firstNew || { id: a.id, type: 'audio' };
      } else {
        const c = { id: uid(), mediaId: m.id, in: 0, out: m.type === 'image' ? 3 : m.duration, speed: 1, volume: 1, filter: 'none', b: 0, c: 0, s: 0, blur: 0, fit: 'contain', zoom: 1, rot: 0, flip: false, trans: 'none', tdur: .5, motion: m.type === 'image' ? 'zoomIn' : 'none' };
        project.main.push(c);
      }
      added++;
    } catch (e) { console.warn(e); toast(`No se pudo abrir “${f.name}”`); }
  }
  if (added) { commit(); if (navigator.storage?.persist) navigator.storage.persist().catch(() => {}); }
}

// ---------- elementos de reproducción + audio ----------
function getEl(clip) {
  let el = els.get(clip.id); if (el) return el;
  const m = media.get(clip.mediaId); if (!m) return null;
  if (m.type === 'image') { el = new Image(); el.decoding = 'async'; el.onload = markDirty; el.src = m.url; }
  else {
    el = document.createElement(m.type === 'audio' ? 'audio' : 'video');
    el.preload = 'auto'; el.playsInline = true; el.setAttribute('playsinline', '');
    for (const ev of ['loadeddata', 'seeked', 'canplay']) el.addEventListener(ev, markDirty);
    el.src = m.url; pool.append(el);
    if (actx) connectEl(el);
  }
  els.set(clip.id, el); return el;
}
function connectEl(el) {
  if (el._gain || el.tagName === 'IMG') return;
  try { const src = actx.createMediaElementSource(el); const g = actx.createGain(); src.connect(g); g.connect(master); el._gain = g; } catch (e) { console.warn(e); }
}
function setVol(el, v) {
  if (el._gain) el._gain.gain.value = v; else el.volume = clamp(v, 0, 1);
}
function ensureAudio() {
  if (actx) { if (actx.state === 'suspended') actx.resume().catch(() => {}); return; }
  const AC = window.AudioContext || window.webkitAudioContext; if (!AC) return;
  try {
    actx = new AC(); master = actx.createGain(); master.connect(actx.destination);
    if (actx.createMediaStreamDestination) { recDest = actx.createMediaStreamDestination(); master.connect(recDest); }
    for (const el of els.values()) connectEl(el);
  } catch (e) { console.warn(e); actx = null; }
}
function pruneEls() {
  for (const [id, el] of els) {
    if (findClip(id)) continue;
    if (el.tagName !== 'IMG') { el.pause(); try { el._gain?.disconnect(); } catch {} el.removeAttribute('src'); el.load(); el.remove(); }
    els.delete(id);
  }
}

// ---------- sincronización de medios ----------
function driveMedia(clip, target, active, rate, vol, keep) {
  const m = media.get(clip.mediaId); const el = getEl(clip); if (!el || !m) return;
  keep.add(clip.id);
  if (m.type === 'image') return;
  if (active) { if (el.playbackRate !== rate) el.playbackRate = rate; setVol(el, vol); }
  if (active && playing) {
    if (!el.seeking && Math.abs(el.currentTime - target) > 0.3) el.currentTime = target;
    if (el.paused) el.play().catch(() => {});
  } else {
    if (!el.paused) el.pause();
    if (!el.seeking && Math.abs(el.currentTime - target) > 0.04) el.currentTime = target;
  }
}
function syncMedia(t, seq) {
  const keep = new Set();
  const i = seq.findIndex(e => t >= e.start && t < e.end);
  if (i >= 0) {
    const e = seq[i], c = e.c;
    driveMedia(c, c.in + (t - e.start) * c.speed, true, c.speed, c.volume, keep);
    if (i > 0 && OVERLAP_TRANS.includes(c.trans) && t - e.start < c.tdur) { const p = seq[i - 1].c; driveMedia(p, Math.max(p.in, p.out - 0.04), false, 1, 0, keep); }
    if (seq[i + 1]) { const n = seq[i + 1].c; driveMedia(n, n.in, false, 1, 0, keep); }
  } else if (seq[0] && t < seq[0].start + 0.01) driveMedia(seq[0].c, seq[0].c.in, false, 1, 0, keep);
  for (const a of project.audios) {
    const d = audDur(a), lt = t - a.start;
    if (lt >= 0 && lt < d) {
      let g = a.volume;
      if (a.fadeIn > 0) g *= clamp(lt / a.fadeIn, 0, 1);
      if (a.fadeOut > 0) g *= clamp((d - lt) / a.fadeOut, 0, 1);
      driveMedia(a, a.in + lt, true, 1, g, keep);
    } else if (lt < 0 && lt > -1.5) driveMedia(a, a.in, false, 1, 0, keep);
  }
  for (const [id, el] of els) if (!keep.has(id) && el.tagName !== 'IMG' && !el.paused) el.pause();
}

// ---------- renderizado ----------
function buildFilter(c) {
  const p = [FILTERS[c.filter]?.f || ''];
  if (c.b) p.push(`brightness(${(1 + c.b / 100).toFixed(2)})`);
  if (c.c) p.push(`contrast(${(1 + c.c / 100).toFixed(2)})`);
  if (c.s) p.push(`saturate(${(1 + c.s / 100).toFixed(2)})`);
  if (c.blur) p.push(`blur(${(c.blur * cv.width / 1080).toFixed(1)}px)`);
  return p.join(' ').trim();
}
function srcSize(el, m) { return m.type === 'image' ? [el.naturalWidth, el.naturalHeight] : [el.videoWidth, el.videoHeight]; }
function drawBlurBg(el, sw, sh) {
  const W = cv.width, H = cv.height, bw = Math.max(8, Math.round(W / 22)), bh = Math.max(8, Math.round(H / 22));
  if (small.width !== bw || small.height !== bh) { small.width = bw; small.height = bh; }
  const s = Math.max(bw / sw, bh / sh);
  sctx.drawImage(el, (bw - sw * s) / 2, (bh - sh * s) / 2, sw * s, sh * s);
  ctx.save(); ctx.filter = 'none'; ctx.globalAlpha = 1; ctx.imageSmoothingEnabled = true; ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(small, 0, 0, W, H); ctx.fillStyle = 'rgba(0,0,0,.28)'; ctx.fillRect(0, 0, W, H); ctx.restore();
}
function drawClip(e, lt, q) {
  const c = e.c, m = media.get(c.mediaId), el = getEl(c); if (!m || !el) return;
  if (m.type === 'video' && el.readyState < 2) return;
  const [sw, sh] = srcSize(el, m); if (!sw || !sh) return;
  const W = cv.width, H = cv.height, dur = e.end - e.start;
  const rot = ((c.rot % 360) + 360) % 360, side = rot % 180 !== 0;
  const iw = side ? sh : sw, ih = side ? sw : sh;
  if (project.bg === 'blur' && c.fit === 'contain') drawBlurBg(el, sw, sh);
  let s = (c.fit === 'cover' ? Math.max(W / iw, H / ih) : Math.min(W / iw, H / ih)) * (c.zoom || 1);
  let dx = 0, dy = 0, alpha = 1, extra = '', flash = 0;
  const p = clamp(lt / Math.max(dur, .01), 0, 1);
  switch (c.motion) {
    case 'zoomIn': s *= 1 + .16 * p; break;
    case 'zoomOut': s *= 1.16 - .16 * p; break;
    case 'panL': s *= 1.15; dx = (.5 - p) * .13 * W; break;
    case 'panR': s *= 1.15; dx = (p - .5) * .13 * W; break;
  }
  if (q != null) switch (c.trans) {
    case 'fade': case 'black': alpha = q; break;
    case 'zoom': s *= 1.25 - .25 * q; alpha = q; break;
    case 'slideL': dx += (1 - q) * W; break;
    case 'slideU': dy += (1 - q) * H; break;
    case 'blur': extra = ` blur(${((1 - q) * 30 * W / 1080).toFixed(1)}px)`; alpha = q; break;
    case 'flash': flash = 1 - q; break;
  }
  ctx.save(); ctx.globalAlpha = alpha;
  const f = (buildFilter(c) + extra).trim(); ctx.filter = f || 'none';
  ctx.translate(W / 2 + dx, H / 2 + dy);
  if (rot) ctx.rotate(rot * Math.PI / 180);
  if (c.flip) ctx.scale(-1, 1);
  ctx.drawImage(el, -sw * s / 2, -sh * s / 2, sw * s, sh * s);
  ctx.restore();
  if (flash > 0) { ctx.fillStyle = `rgba(255,255,255,${flash.toFixed(3)})`; ctx.fillRect(0, 0, W, H); }
}
function roundRect(x, y, w, hh, r) {
  ctx.beginPath(); if (ctx.roundRect) ctx.roundRect(x, y, w, hh, r); else ctx.rect(x, y, w, hh);
}
function drawText(x, t) {
  const W = cv.width, H = cv.height, lt = t - x.start, rem = x.start + x.dur - t, AD = .4;
  let a = 1, sc = 1, oy = 0, chars = Infinity;
  if (lt < AD) {
    const p = lt / AD, q = ease(p);
    if (x.animIn === 'fade') a = q;
    else if (x.animIn === 'pop') { sc = backOut(p); a = clamp(p * 3, 0, 1); }
    else if (x.animIn === 'slide') { oy = (1 - q) * H * .06; a = q; }
    else if (x.animIn === 'zoom') { sc = 1.8 - .8 * q; a = q; }
  }
  if (x.animIn === 'type') chars = Math.floor(lt * 20);
  if (rem < AD) {
    const q = ease(rem / AD);
    if (x.animOut === 'fade') a *= q;
    else if (x.animOut === 'pop') sc *= q;
    else if (x.animOut === 'slide') { oy -= (1 - q) * H * .06; a *= q; }
  }
  const k = Math.min(W, H) / 1080, fs = x.size * k, F = FONTS.find(f => f.id === x.font) || FONTS[0];
  ctx.save();
  ctx.font = `${F.w} ${fs}px "${F.id}", sans-serif`;
  const lines = (x.text || ' ').split('\n'), lh = fs * 1.2;
  const widths = lines.map(l => ctx.measureText(l).width), maxW = Math.max(fs * .4, ...widths);
  const padX = x.bg ? fs * .45 : fs * .15, padY = x.bg ? fs * .28 : fs * .1;
  const bw = maxW + padX * 2, bh = lines.length * lh + padY * 2, cx = x.x * W, cy = x.y * H;
  textBoxes.set(x.id, { x: cx - bw / 2, y: cy - bh / 2, w: bw, h: bh });
  ctx.translate(cx, cy + oy); ctx.scale(Math.max(sc, .001), Math.max(sc, .001)); ctx.globalAlpha = clamp(a, 0, 1);
  if (x.bg) { ctx.fillStyle = hexA(x.bgColor, x.bgAlpha); roundRect(-bw / 2, -bh / 2, bw, bh, fs * .22); ctx.fill(); }
  ctx.textAlign = 'left'; ctx.textBaseline = 'middle'; ctx.lineJoin = 'round'; ctx.miterLimit = 2;
  let left = chars;
  lines.forEach((ln, i) => {
    let s = ln;
    if (left !== Infinity) { s = ln.slice(0, Math.max(0, left)); left -= ln.length + 1; }
    if (!s) return;
    const y = (i - (lines.length - 1) / 2) * lh + fs * .04, x0 = -widths[i] / 2;
    if (x.shadow === 'drop') { ctx.shadowColor = 'rgba(0,0,0,.55)'; ctx.shadowBlur = fs * .14; ctx.shadowOffsetY = fs * .05; }
    else if (x.shadow === 'glow') { ctx.shadowColor = x.color; ctx.shadowBlur = fs * .45; }
    if (x.stroke && x.strokeW > 0) { ctx.strokeStyle = x.strokeColor; ctx.lineWidth = x.strokeW * k * 2; ctx.strokeText(s, x0, y); ctx.shadowColor = 'transparent'; }
    ctx.fillStyle = x.color; ctx.fillText(s, x0, y);
    if (x.shadow === 'glow') { ctx.shadowBlur = fs * .15; ctx.fillText(s, x0, y); }
    ctx.shadowColor = 'transparent';
  });
  ctx.restore();
}
function render(t, seq) {
  const W = cv.width, H = cv.height;
  const i = seq.findIndex(e => t >= e.start && t < e.end), cur = seq[i];
  stalled = false;
  if (cur) {
    const m = media.get(cur.c.mediaId), el = getEl(cur.c);
    if (m?.type === 'video' && el && (el.readyState < 2 || (exporting && el.seeking)) && !el.error) {
      if (!stallStart) stallStart = performance.now();
      if (performance.now() - stallStart < 2000) { stalled = true; return; }
    } else stallStart = 0;
  }
  ctx.save(); ctx.filter = 'none'; ctx.globalAlpha = 1;
  ctx.fillStyle = project.bg === 'blur' ? '#000' : project.bg; ctx.fillRect(0, 0, W, H);
  if (cur) {
    const c = cur.c, lt = t - cur.start, inTrans = i > 0 && c.trans !== 'none' && lt < c.tdur;
    if (inTrans && OVERLAP_TRANS.includes(c.trans)) { const pe = seq[i - 1]; drawClip(pe, pe.end - pe.start, null); }
    drawClip(cur, lt, inTrans ? ease(lt / c.tdur) : null);
  }
  for (const x of project.texts) if (t >= x.start && t < x.start + x.dur) drawText(x, t);
  if (sel?.type === 'text' && !exporting) {
    const x = findClip(sel.id)?.c, b = textBoxes.get(sel.id);
    if (x && b && t >= x.start && t < x.start + x.dur) {
      const lw = Math.max(2, W / 360);
      ctx.strokeStyle = '#fff'; ctx.lineWidth = lw; ctx.setLineDash([lw * 4, lw * 3]);
      ctx.strokeRect(b.x - lw * 2, b.y - lw * 2, b.w + lw * 4, b.h + lw * 4); ctx.setLineDash([]);
    }
  }
  ctx.restore();
}

// ---------- bucle principal ----------
let lastTimeStr = '';
function tick(ts) {
  requestAnimationFrame(tick);
  if (playing) {
    const dt = Math.min(.1, (ts - lastTs) / 1000); lastTs = ts;
    if (!stalled) curT += dt;
    const T = totalDur();
    if (curT >= T) { curT = T; if (exporting) { stopExport(true); } else pause(); }
    dirty = true;
  }
  if (!dirty) return;
  dirty = false;
  const seq = mainSeq(), t = previewT ?? curT;
  syncMedia(t, seq); render(t, seq);
  if (exporting) {
    const T = totalDur() || 1, pct = Math.round(clamp(curT / T, 0, 1) * 100);
    $('#expBar').style.width = pct + '%'; $('#expPct').textContent = pct + '%';
    return;
  }
  if (previewT == null) setScrollFromT();
  const s = `<b>${fmt(t)}</b> / ${fmt(totalDur())}`;
  if (s !== lastTimeStr) { $('#tTime').innerHTML = s; lastTimeStr = s; }
}
function play() {
  if (playing) return;
  ensureAudio();
  const T = totalDur(); if (T <= 0) return toast('Añade algo primero');
  if (curT >= T - .05) curT = 0;
  playing = true; lastTs = performance.now(); stallStart = 0;
  syncMedia(curT, mainSeq()); // dentro del gesto del usuario (necesario en iOS)
  $('#btnPlay').innerHTML = ic('pause'); markDirty();
}
function pause() {
  playing = false;
  for (const el of els.values()) if (el.tagName !== 'IMG' && !el.paused) el.pause();
  $('#btnPlay').innerHTML = ic('play'); markDirty();
}
const togglePlay = () => (playing ? pause() : play());

// ---------- lienzo ----------
function resizeCanvas() {
  const [w, hh] = dims(project.ratio, 720);
  cv.width = w; cv.height = hh; fitCanvas(); markDirty();
}
function fitCanvas() {
  const r = $('#stage').getBoundingClientRect();
  const s = Math.min((r.width - 24) / cv.width, (r.height - 20) / cv.height);
  if (s > 0) { cv.style.width = Math.floor(cv.width * s) + 'px'; cv.style.height = Math.floor(cv.height * s) + 'px'; }
}
const toCv = e => { const r = cv.getBoundingClientRect(); return { x: (e.clientX - r.left) * cv.width / r.width, y: (e.clientY - r.top) * cv.height / r.height }; };
(() => {
  const ptrs = new Map(); let drag = null, pinch = null;
  const dist = () => { const [a, b] = [...ptrs.values()]; return Math.hypot(a.x - b.x, a.y - b.y); };
  cv.addEventListener('pointerdown', e => {
    if (exporting) return;
    try { cv.setPointerCapture(e.pointerId); } catch {}
    ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (ptrs.size === 2 && sel?.type === 'text') { pinch = { d0: dist(), s0: findClip(sel.id).c.size }; drag = null; return; }
    if (ptrs.size > 1) return;
    const p = toCv(e), t = curT;
    const hit = project.texts.filter(x => t >= x.start && t < x.start + x.dur).reverse().find(x => {
      const b = textBoxes.get(x.id); return b && p.x >= b.x - 10 && p.x <= b.x + b.w + 10 && p.y >= b.y - 10 && p.y <= b.y + b.h + 10;
    });
    if (hit) {
      const wasSel = isSel(hit.id); if (!wasSel) select(hit.id, 'text');
      drag = { x: hit, sx: p.x, sy: p.y, ox: hit.x, oy: hit.y, moved: false, wasSel };
    } else { drag = null; if (sel) select(null); }
  });
  cv.addEventListener('pointermove', e => {
    if (!ptrs.has(e.pointerId)) return;
    ptrs.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pinch && ptrs.size >= 2) { const x = findClip(sel?.id)?.c; if (x) { x.size = clamp(Math.round(pinch.s0 * dist() / pinch.d0), 12, 400); markDirty(); } return; }
    if (!drag) return;
    const p = toCv(e), dx = p.x - drag.sx, dy = p.y - drag.sy;
    if (!drag.moved && Math.hypot(dx, dy) < 6) return;
    drag.moved = true;
    let nx = drag.ox + dx / cv.width, ny = drag.oy + dy / cv.height;
    if (Math.abs(nx - .5) < .02) nx = .5; // imán al centro
    drag.x.x = clamp(nx, 0, 1); drag.x.y = clamp(ny, 0, 1); markDirty();
  });
  const up = e => {
    ptrs.delete(e.pointerId);
    if (pinch) { if (ptrs.size < 2) { pinch = null; commit(); } return; }
    if (drag) { if (drag.moved) commit(); else if (drag.wasSel) openTextEditor(drag.x); drag = null; }
  };
  cv.addEventListener('pointerup', up); cv.addEventListener('pointercancel', up);
})();

// ---------- línea de tiempo ----------
const divs = new Map(), tbtns = new Map();
let addEnd = null, hintText = null, hintAudio = null, lastScrollSet = -1;
const LANE_T = 28, LANE_A = 32;

function lanes(items, startF, endF) {
  const order = [...items].sort((a, b) => startF(a) - startF(b)), ends = [], map = new Map();
  for (const it of order) {
    let l = ends.findIndex(e => e <= startF(it) + 1e-6);
    if (l < 0) { l = ends.length; ends.push(0); }
    ends[l] = endF(it); map.set(it.id, l);
  }
  return { map, count: Math.max(1, ends.length) };
}
function handles(d, clip, type) {
  const l = h('div', { class: 'h l' }), r = h('div', { class: 'h r' });
  bindHandle(l, clip, type, 'l'); bindHandle(r, clip, type, 'r'); d.append(l, r);
}
function buildTimeline() {
  divs.clear(); tbtns.clear();
  rowMain.innerHTML = ''; rowText.innerHTML = ''; rowAudio.innerHTML = '';
  project.main.forEach((c, i) => {
    const m = media.get(c.mediaId);
    const d = h('div', { class: 'clip main' + (isSel(c.id) ? ' sel' : '') });
    if (m?.thumb) d.style.backgroundImage = `url("${m.thumb}")`;
    const badges = [];
    if (c.speed !== 1) badges.push(c.speed + 'x');
    if (m?.type === 'video' && c.volume === 0) badges.push('🔇');
    if (c.filter !== 'none') badges.push(FILTERS[c.filter].n);
    if (badges.length) d.append(h('span', { class: 'badge' }, badges.join(' · ')));
    if (isSel(c.id)) handles(d, c, 'main');
    bindClip(d, c, 'main'); divs.set(c.id, d); rowMain.append(d);
    if (i > 0) {
      const b = h('button', { class: 'tbtn' + (c.trans !== 'none' ? ' on' : ''), html: ic('trans'), title: 'Transición' });
      b.addEventListener('pointerdown', e => e.stopPropagation());
      b.addEventListener('click', e => { e.stopPropagation(); select(c.id, 'main'); openTransition(c); });
      rowMain.append(b); tbtns.set(c.id, b);
    }
  });
  addEnd = h('button', { class: 'add-end', html: ic('plus'), title: 'Añadir medios', onclick: () => $('#fileMedia').click() });
  rowMain.append(addEnd);
  for (const x of project.texts) {
    const d = h('div', { class: 'clip text' + (isSel(x.id) ? ' sel' : '') }, h('span', { class: 'lbl' }, (x.text || ' ').split('\n')[0] || ' '));
    if (isSel(x.id)) handles(d, x, 'text');
    bindClip(d, x, 'text'); divs.set(x.id, d); rowText.append(d);
  }
  for (const a of project.audios) {
    const m = media.get(a.mediaId);
    const d = h('div', { class: 'clip audio' + (isSel(a.id) ? ' sel' : '') }, h('span', { class: 'lbl' }, '♪ ' + (m?.name || 'Audio')));
    if (m?.wave) d.style.backgroundImage = `url("${m.wave}")`;
    if (isSel(a.id)) handles(d, a, 'audio');
    bindClip(d, a, 'audio'); divs.set(a.id, d); rowAudio.append(d);
  }
  hintText = hintAudio = null;
  if (!project.texts.length) { hintText = h('button', { class: 'row-hint', html: ic('plus') + 'Añadir texto', onclick: openTemplates }); rowText.append(hintText); }
  if (!project.audios.length) { hintAudio = h('button', { class: 'row-hint', html: ic('plus') + 'Añadir audio', onclick: () => $('#fileAudio').click() }); rowAudio.append(hintAudio); }
  layoutTimeline();
}
function layoutTimeline() {
  const pad = Math.round(tl.clientWidth / 2), seq = mainSeq(), T = totalDur();
  tlInner.style.width = (pad * 2 + T * pps + 80) + 'px';
  // regla
  const steps = [.5, 1, 2, 5, 10, 15, 30, 60, 120, 300];
  const step = steps.find(s => s * pps >= 64) || 300, minor = step / 2;
  const frag = document.createDocumentFragment(), end = T + (tl.clientWidth / 2) / pps;
  for (let s = 0; s <= end; s += minor) {
    const major = Math.abs(s / step - Math.round(s / step)) < 1e-6;
    frag.append(h('span', { class: 'tick' + (major ? '' : ' minor'), style: `left:${pad + s * pps}px` }, major ? fmtTick(s) : ''));
  }
  ruler.replaceChildren(frag);
  for (const e of seq) {
    const d = divs.get(e.c.id);
    if (d) { d.style.left = (pad + e.start * pps) + 'px'; d.style.width = Math.max(8, (e.end - e.start) * pps - 2) + 'px'; }
    const b = tbtns.get(e.c.id); if (b) b.style.left = (pad + e.start * pps - 1) + 'px';
  }
  if (addEnd) addEnd.style.left = (pad + (seq.length ? seq[seq.length - 1].end : 0) * pps + 10) + 'px';
  const lt = lanes(project.texts, x => x.start, x => x.start + x.dur);
  rowText.style.height = lt.count * LANE_T - 2 + 'px';
  for (const x of project.texts) {
    const d = divs.get(x.id); if (!d) continue;
    d.style.left = (pad + x.start * pps) + 'px'; d.style.width = Math.max(8, x.dur * pps - 2) + 'px'; d.style.top = lt.map.get(x.id) * LANE_T + 'px';
  }
  const la = lanes(project.audios, a => a.start, a => a.start + audDur(a));
  rowAudio.style.height = la.count * LANE_A - 2 + 'px';
  for (const a of project.audios) {
    const d = divs.get(a.id), m = media.get(a.mediaId); if (!d) continue;
    d.style.left = (pad + a.start * pps) + 'px'; d.style.width = Math.max(8, audDur(a) * pps - 2) + 'px'; d.style.top = la.map.get(a.id) * LANE_A + 'px';
    if (m) { d.style.backgroundSize = `${m.duration * pps}px 100%`; d.style.backgroundPosition = `${-a.in * pps}px 0`; }
  }
  for (const hint of [hintText, hintAudio]) if (hint) hint.style.left = (pad + curT * pps + 8) + 'px';
}
function setScrollFromT(force) {
  const x = Math.round(curT * pps);
  if (force || Math.abs(tl.scrollLeft - x) >= 1) { lastScrollSet = x; tl.scrollLeft = x; }
}
function setPps(v) { pps = clamp(v, 6, 480); layoutTimeline(); setScrollFromT(true); }
tl.addEventListener('scroll', () => {
  if (Math.abs(tl.scrollLeft - lastScrollSet) <= 1) return;
  lastScrollSet = -1;
  if (exporting) return;
  if (playing) pause();
  curT = clamp(tl.scrollLeft / pps, 0, totalDur());
  if (hintText || hintAudio) for (const hint of [hintText, hintAudio]) if (hint) hint.style.left = (Math.round(tl.clientWidth / 2) + curT * pps + 8) + 'px';
  markDirty();
}, { passive: true });
tl.addEventListener('wheel', e => {
  if (e.ctrlKey || e.metaKey) { e.preventDefault(); setPps(pps * (e.deltaY < 0 ? 1.12 : 1 / 1.12)); }
  else if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) { e.preventDefault(); tl.scrollLeft += e.deltaY; }
}, { passive: false });
let pinchTl = null;
const tdist = ts => Math.hypot(ts[0].clientX - ts[1].clientX, ts[0].clientY - ts[1].clientY);
tl.addEventListener('touchstart', e => { if (e.touches.length === 2) pinchTl = { d0: tdist(e.touches), p0: pps }; }, { passive: true });
tl.addEventListener('touchmove', e => {
  if (dragActive) { e.preventDefault(); return; }
  if (pinchTl && e.touches.length === 2) { e.preventDefault(); setPps(pinchTl.p0 * tdist(e.touches) / pinchTl.d0); }
}, { passive: false });
tl.addEventListener('touchend', e => { if (e.touches.length < 2) pinchTl = null; });
tl.addEventListener('contextmenu', e => e.preventDefault());
for (const row of [rowMain, rowText, rowAudio, tlInner, ruler]) row.addEventListener('click', e => { if (e.target === row && sel) select(null); });

function snapTime(ns, clip, dur) {
  const th = 10 / pps, cands = [curT, 0];
  for (const e of mainSeq()) cands.push(e.start, e.end);
  for (const x of project.texts) if (x !== clip) cands.push(x.start, x.start + x.dur);
  for (const a of project.audios) if (a !== clip) cands.push(a.start, a.start + audDur(a));
  let best = ns, bd = th;
  for (const c of cands) {
    if (Math.abs(ns - c) < bd) { bd = Math.abs(ns - c); best = c; }
    if (Math.abs(ns + dur - c) < bd) { bd = Math.abs(ns + dur - c); best = c - dur; }
  }
  return Math.max(0, best);
}
function bindClip(div, clip, type) {
  div.addEventListener('pointerdown', ev => {
    if (ev.button > 0 || ev.target.closest('.h') || exporting) return;
    const sx = ev.clientX, sy = ev.clientY, touch = ev.pointerType !== 'mouse';
    let dragging = false, moved = false, timer = 0;
    const me = type === 'main' ? mainSeq().find(x => x.c === clip) : null;
    const startPos = type === 'main' ? me.start : clip.start;
    const dur = type === 'main' ? me.end - me.start : type === 'text' ? clip.dur : audDur(clip);
    const begin = () => {
      if (pinchTl) return cleanup();
      dragging = true; dragActive = true; div.classList.add('dragging');
      if (navigator.vibrate) try { navigator.vibrate(12); } catch {}
      if (!isSel(clip.id)) { for (const d of divs.values()) d.classList.remove('sel'); div.classList.add('sel'); sel = { id: clip.id, type }; buildToolbar(); markDirty(); }
    };
    if (touch) timer = setTimeout(begin, 350);
    const move = e => {
      const dx = e.clientX - sx, dy = e.clientY - sy;
      if (!dragging) {
        if (Math.hypot(dx, dy) > 7) { moved = true; clearTimeout(timer); if (!touch) begin(); else return cleanup(); }
        else return;
      }
      if (type === 'main') div.style.transform = `translateX(${dx}px)`;
      else { clip.start = snapTime(Math.max(0, startPos + dx / pps), clip, dur); layoutTimeline(); markDirty(); }
    };
    const up = e => {
      cleanup();
      if (dragging) {
        dragActive = false; div.classList.remove('dragging');
        if (type === 'main') {
          const center = startPos + dur / 2 + (e.clientX - sx) / pps;
          const others = mainSeq().filter(x => x.c !== clip);
          const idx = others.filter(x => (x.start + x.end) / 2 < center).length;
          const arr = project.main; arr.splice(arr.indexOf(clip), 1); arr.splice(idx, 0, clip);
          div.style.transform = '';
        }
        commit();
      } else if (!moved && e.type === 'pointerup') select(clip.id, type);
    };
    function cleanup() {
      clearTimeout(timer);
      window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up); window.removeEventListener('pointercancel', up);
    }
    window.addEventListener('pointermove', move); window.addEventListener('pointerup', up); window.addEventListener('pointercancel', up);
  });
}
function bindHandle(hd, clip, type, side) {
  hd.addEventListener('pointerdown', ev => {
    ev.stopPropagation(); ev.preventDefault();
    try { hd.setPointerCapture(ev.pointerId); } catch {}
    if (playing) pause();
    const sx = ev.clientX, o = { ...clip }, m = media.get(clip.mediaId);
    const srcDur = !m ? Infinity : m.type === 'image' ? 3600 : m.duration;
    dragActive = true;
    const mv = e => {
      const dt = (e.clientX - sx) / pps;
      if (type === 'main') {
        if (side === 'l') clip.in = clamp(o.in + dt * o.speed, 0, o.out - .1 * o.speed);
        else clip.out = clamp(o.out + dt * o.speed, o.in + .1 * o.speed, srcDur);
        const e2 = mainSeq().find(x => x.c === clip); previewT = side === 'l' ? e2.start : e2.end - .03;
      } else if (type === 'text') {
        if (side === 'l') { const ns = clamp(o.start + dt, 0, o.start + o.dur - .2); clip.dur = o.dur + (o.start - ns); clip.start = ns; previewT = ns + .01; }
        else { clip.dur = Math.max(.2, o.dur + dt); previewT = clip.start + clip.dur - .03; }
      } else {
        if (side === 'l') { const d = clamp(dt, Math.max(-o.in, -o.start), (o.out - o.in) - .1); clip.in = o.in + d; clip.start = o.start + d; previewT = clip.start; }
        else { clip.out = clamp(o.out + dt, o.in + .1, srcDur); previewT = clip.start + audDur(clip) - .03; }
      }
      layoutTimeline(); markDirty();
    };
    const up = () => {
      hd.removeEventListener('pointermove', mv); hd.removeEventListener('pointerup', up); hd.removeEventListener('pointercancel', up);
      dragActive = false; previewT = null; commit();
    };
    hd.addEventListener('pointermove', mv); hd.addEventListener('pointerup', up); hd.addEventListener('pointercancel', up);
  });
}

// ---------- selección y acciones ----------
function select(id, type) {
  sel = id ? { id, type } : null;
  closeSheet(); buildTimeline(); buildToolbar(); markDirty();
}
function splitAtPlayhead() {
  const t = curT;
  if (!sel || sel.type === 'main') {
    const e = mainSeq().find(e => t > e.start + .05 && t < e.end - .05 && (!sel || e.c.id === sel.id));
    if (!e) return toast('Coloca la línea blanca dentro del clip');
    const c = e.c, cut = c.in + (t - e.start) * c.speed;
    const n = { ...structuredClone(c), id: uid(), in: cut, trans: 'none' };
    c.out = cut; project.main.splice(project.main.indexOf(c) + 1, 0, n);
  } else if (sel.type === 'text') {
    const x = findClip(sel.id).c;
    if (!(t > x.start + .1 && t < x.start + x.dur - .1)) return toast('Coloca la línea blanca dentro del texto');
    const n = { ...structuredClone(x), id: uid(), start: t, dur: x.start + x.dur - t }; x.dur = t - x.start; project.texts.push(n);
  } else {
    const a = findClip(sel.id).c;
    if (!(t > a.start + .1 && t < a.start + audDur(a) - .1)) return toast('Coloca la línea blanca dentro del audio');
    const cut = a.in + (t - a.start), n = { ...structuredClone(a), id: uid(), start: t, in: cut, fadeIn: 0 }; a.out = cut; a.fadeOut = 0; project.audios.push(n);
  }
  commit(); toast('Dividido');
}
function deleteSel() {
  if (!sel) return; const f = findClip(sel.id); if (!f) return;
  f.arr.splice(f.arr.indexOf(f.c), 1); sel = null; closeSheet(false); commit(); buildToolbar();
}
function duplicateSel() {
  if (!sel) return; const f = findClip(sel.id); if (!f) return;
  const n = { ...structuredClone(f.c), id: uid() };
  if (f.type === 'main') { n.trans = 'none'; f.arr.splice(f.arr.indexOf(f.c) + 1, 0, n); }
  else if (f.type === 'text') { n.start = f.c.start + f.c.dur; f.arr.push(n); }
  else { n.start = f.c.start + audDur(f.c); f.arr.push(n); }
  sel = { id: n.id, type: f.type }; commit(); buildToolbar(); toast('Duplicado');
}
function moveMain(dir) {
  const f = findClip(sel?.id); if (!f || f.type !== 'main') return;
  const i = f.arr.indexOf(f.c), j = i + dir; if (j < 0 || j >= f.arr.length) return;
  [f.arr[i], f.arr[j]] = [f.arr[j], f.arr[i]]; commit();
}
function addText(style) {
  const x = { id: uid(), start: curT, dur: 3, ...structuredClone(TEXT_BASE), ...structuredClone(style) };
  if (x.start >= totalDur() - .1 && project.main.length) x.start = Math.max(0, totalDur() - 3);
  project.texts.push(x); document.fonts?.load?.(`40px "${x.font}"`).then(markDirty).catch(() => {});
  sel = { id: x.id, type: 'text' }; commit(); buildToolbar(); openTextEditor(x, 'text');
}

// ---------- barra de herramientas ----------
function toolBtn(icon, label, fn, cls = '') {
  return h('button', { class: 'tool ' + cls, html: ic(icon) + (label ? `<span>${label}</span>` : ''), onclick: fn });
}
function buildToolbar() {
  const tb = $('#toolbar'); tb.innerHTML = '';
  const f = sel && findClip(sel.id);
  if (!f) {
    tb.append(
      toolBtn('plus', 'Medios', () => $('#fileMedia').click()),
      toolBtn('text', 'Texto', openTemplates),
      toolBtn('music', 'Audio', () => $('#fileAudio').click()),
      toolBtn('split', 'Dividir', splitAtPlayhead),
      toolBtn('ratio', 'Formato', openRatio),
      toolBtn('bg', 'Fondo', openBg),
    );
    return;
  }
  const c = f.c, back = toolBtn('back', '', () => select(null), 'back');
  if (f.type === 'main') {
    const m = media.get(c.mediaId), isImg = m?.type === 'image';
    tb.append(back,
      toolBtn('split', 'Dividir', splitAtPlayhead),
      isImg ? toolBtn('clock', 'Duración', () => openDuration(c)) : toolBtn('speed', 'Velocidad', () => openSpeed(c)),
      !isImg && toolBtn('volume', 'Volumen', () => openVolume(c)),
      toolBtn('filter', 'Filtros', () => openFilters(c)),
      toolBtn('adjust', 'Ajustes', () => openAdjust(c)),
      toolBtn('trans', 'Transición', () => openTransition(c)),
      toolBtn('motion', 'Movimiento', () => openMotion(c)),
      toolBtn('crop', 'Encuadre', () => openFrame(c)),
      toolBtn('copy', 'Duplicar', duplicateSel),
      toolBtn('left', 'Mover', () => moveMain(-1)),
      toolBtn('right', 'Mover', () => moveMain(1)),
      toolBtn('trash', 'Eliminar', deleteSel, 'danger'),
    );
  } else if (f.type === 'text') {
    tb.append(back,
      toolBtn('edit', 'Editar', () => openTextEditor(c, 'text')),
      toolBtn('text', 'Estilo', () => openTextEditor(c, 'style')),
      toolBtn('motion', 'Animación', () => openTextEditor(c, 'anim')),
      toolBtn('split', 'Dividir', splitAtPlayhead),
      toolBtn('copy', 'Duplicar', duplicateSel),
      toolBtn('trash', 'Eliminar', deleteSel, 'danger'),
    );
  } else {
    tb.append(back,
      toolBtn('volume', 'Volumen', () => openAudioVol(c)),
      toolBtn('split', 'Dividir', splitAtPlayhead),
      toolBtn('copy', 'Duplicar', duplicateSel),
      toolBtn('trash', 'Eliminar', deleteSel, 'danger'),
    );
  }
}

// ---------- hoja inferior y controles ----------
function openSheet(title, ...content) {
  $('#sheetTitle').textContent = title;
  $('#sheetBody').replaceChildren(...content.flat().filter(Boolean));
  $('#sheet').classList.remove('closed'); $('#scrim').classList.remove('hidden');
}
function closeSheet(doCommit = true) {
  const open = !$('#sheet').classList.contains('closed');
  $('#sheet').classList.add('closed'); $('#scrim').classList.add('hidden');
  document.activeElement?.blur?.();
  if (open && doCommit) commit();
}
const section = (title, ...kids) => h('div', {}, h('div', { class: 'sec-title' }, title), ...kids);
function slider(label, min, max, step, val, show, onInput) {
  const out = h('span', { class: 'val' }, show(val));
  const inp = h('input', { type: 'range', min, max, step }); inp.value = val;
  inp.addEventListener('input', () => { const v = +inp.value; out.textContent = show(v); onInput(v); markDirty(); });
  inp.addEventListener('change', () => commit());
  return h('label', { class: 'ctl' }, h('div', { class: 'ctl-top' }, h('span', {}, label), out), inp);
}
function chips(opts, cur, onPick, cls = 'chips') {
  const row = h('div', { class: cls });
  for (const o of opts) {
    const b = h('button', { class: 'chip' + (o.v === cur ? ' on' : '') }, o.el || o.n);
    b.onclick = () => { row.querySelectorAll('.chip').forEach(x => x.classList.remove('on')); b.classList.add('on'); onPick(o.v); markDirty(); };
    row.append(b);
  }
  return row;
}
function swatches(cur, set, extra = []) {
  const row = h('div', { class: 'swatches' });
  const mk = (v, el) => {
    el.onclick = () => { row.querySelectorAll('.sw').forEach(x => x.classList.remove('on')); el.classList.add('on'); set(v); markDirty(); commit(); };
    return el;
  };
  for (const e of extra) row.append(mk(e.v, e.el));
  for (const c of COLORS) row.append(mk(c, h('button', { class: 'sw' + (c === cur ? ' on' : ''), style: `background:${c}`, title: c })));
  const pick = h('input', { type: 'color' }); pick.value = /^#[0-9a-f]{6}$/i.test(cur) ? cur : '#ffffff';
  pick.addEventListener('input', () => { set(pick.value); markDirty(); });
  pick.addEventListener('change', () => commit());
  row.append(h('label', { class: 'sw-custom', title: 'Otro color' }, pick));
  return row;
}
function toggleRow(label, val, onChange) {
  const sw = h('button', { class: 'switch' + (val ? ' on' : ''), 'aria-label': label });
  sw.onclick = () => { val = !val; sw.classList.toggle('on', val); onChange(val); markDirty(); commit(); };
  return h('div', { class: 'toggle-row' }, h('span', {}, label), sw);
}

// --- paneles de clip principal ---
function openSpeed(c) {
  let sl;
  const set = v => { c.speed = v; layoutTimeline(); };
  const presets = chips([.25, .5, 1, 1.5, 2, 3, 4].map(v => ({ v, n: v + 'x' })), c.speed, v => { set(v); sl.querySelector('input').value = v; sl.querySelector('.val').textContent = v + 'x'; commit(); });
  sl = slider('Velocidad', .1, 4, .05, c.speed, v => (+v).toFixed(2).replace(/\.?0+$/, '') + 'x', set);
  openSheet('Velocidad', presets, sl, h('p', { class: 'muted' }, 'El tono del audio se conserva al cambiar la velocidad.'));
}
function openVolume(c) {
  openSheet('Volumen',
    slider('Volumen del clip', 0, 200, 1, Math.round(c.volume * 100), v => v + '%', v => { c.volume = v / 100; }),
    h('div', { class: 'btn-row' },
      h('button', { class: 'ghost', html: ic('volume') + 'Silenciar', onclick: () => { c.volume = 0; commit(); openVolume(c); } }),
      h('button', { class: 'ghost', onclick: () => { c.volume = 1; commit(); openVolume(c); } }, '100%')));
}
function openDuration(c) {
  openSheet('Duración de la foto', slider('Duración', .5, 20, .1, +(c.out - c.in).toFixed(1), v => (+v).toFixed(1) + ' s', v => { c.out = c.in + v; layoutTimeline(); }));
}
function openFilters(c) {
  const m = media.get(c.mediaId), grid = h('div', { class: 'grid' });
  for (const [k, F] of Object.entries(FILTERS)) {
    const b = h('button', { class: 'fbtn' + (c.filter === k ? ' on' : '') }, h('div', { class: 'fimg', style: `background-image:url("${m?.thumb || ''}");filter:${F.f || 'none'}` }), F.n);
    b.onclick = () => { grid.querySelectorAll('.fbtn').forEach(x => x.classList.remove('on')); b.classList.add('on'); c.filter = k; markDirty(); commit(); };
    grid.append(b);
  }
  openSheet('Filtros', grid, h('button', { class: 'ghost', onclick: () => { const f = c.filter; project.main.forEach(x => { x.filter = f; }); commit(); toast('Filtro aplicado a todos'); } }, 'Aplicar a todos los clips'));
}
function openAdjust(c) {
  const pct = v => (v > 0 ? '+' : '') + v;
  openSheet('Ajustes',
    slider('Brillo', -100, 100, 1, c.b, pct, v => { c.b = v; }),
    slider('Contraste', -100, 100, 1, c.c, pct, v => { c.c = v; }),
    slider('Saturación', -100, 100, 1, c.s, pct, v => { c.s = v; }),
    slider('Desenfoque', 0, 30, 1, c.blur || 0, v => v, v => { c.blur = v; }),
    h('button', { class: 'ghost', onclick: () => { c.b = c.c = c.s = c.blur = 0; commit(); openAdjust(c); } }, 'Restablecer'));
}
function openTransition(c) {
  const isFirst = project.main[0] === c;
  openSheet('Transición de entrada',
    isFirst ? h('p', { class: 'muted' }, 'Es el primer clip: la transición se verá como entrada del vídeo.') : null,
    chips(TRANSITIONS, c.trans, v => { c.trans = v; commit(); curT = Math.max(0, (mainSeq().find(e => e.c === c)?.start || 0) - .3); setScrollFromT(true); }, 'chips wrap'),
    slider('Duración', .2, 1.5, .05, c.tdur, v => (+v).toFixed(2) + ' s', v => { c.tdur = v; }),
    h('div', { class: 'btn-row' },
      h('button', { class: 'ghost', onclick: () => { project.main.forEach((x, i) => { if (i > 0) { x.trans = c.trans; x.tdur = c.tdur; } }); commit(); toast('Aplicado a todos'); } }, 'Aplicar a todos'),
      h('button', { class: 'ghost', html: ic('play') + 'Ver', onclick: () => { closeSheet(); curT = Math.max(0, (mainSeq().find(e => e.c === c)?.start || 0) - .6); setScrollFromT(true); play(); } })));
}
function openMotion(c) {
  openSheet('Movimiento', chips(MOTIONS, c.motion, v => { c.motion = v; commit(); }, 'chips wrap'),
    h('p', { class: 'muted' }, 'Efecto “Ken Burns”: un zoom o paneo lento durante todo el clip. Ideal para fotos.'));
}
function openFrame(c) {
  openSheet('Encuadre',
    chips([{ v: 'contain', n: 'Ajustar' }, { v: 'cover', n: 'Rellenar' }], c.fit, v => { c.fit = v; commit(); }, 'seg'),
    slider('Zoom', 50, 300, 1, Math.round((c.zoom || 1) * 100), v => v + '%', v => { c.zoom = v / 100; }),
    h('div', { class: 'btn-row' },
      h('button', { class: 'ghost', html: ic('rotate') + 'Girar 90°', onclick: () => { c.rot = (c.rot + 90) % 360; commit(); } }),
      h('button', { class: 'ghost', html: ic('flip') + 'Espejo', onclick: () => { c.flip = !c.flip; commit(); } })));
}
// --- audio ---
function openAudioVol(a) {
  openSheet('Audio',
    slider('Volumen', 0, 200, 1, Math.round(a.volume * 100), v => v + '%', v => { a.volume = v / 100; }),
    slider('Entrada gradual', 0, 5, .1, a.fadeIn, v => (+v).toFixed(1) + ' s', v => { a.fadeIn = v; }),
    slider('Salida gradual', 0, 5, .1, a.fadeOut, v => (+v).toFixed(1) + ' s', v => { a.fadeOut = v; }));
}
// --- texto ---
function openTemplates() {
  const grid = h('div', { class: 'grid' });
  for (const t of TEMPLATES) {
    const s = { ...TEXT_BASE, ...t.s }, F = FONTS.find(f => f.id === s.font);
    const css = [`font-family:"${s.font}"`, `font-weight:${F.w}`, `color:${s.color}`, `font-size:${clamp(s.size / 5.5, 13, 24)}px`,
      s.stroke ? `-webkit-text-stroke:1px ${s.strokeColor};paint-order:stroke` : '', s.bg ? `background:${hexA(s.bgColor, s.bgAlpha)};padding:3px 6px;border-radius:5px` : '',
      s.shadow === 'glow' ? `text-shadow:0 0 8px ${s.color}` : s.shadow === 'drop' ? 'text-shadow:0 2px 4px #000a' : ''].join(';');
    grid.append(h('button', { class: 'fbtn', onclick: () => { closeSheet(false); addText(t.s); } }, h('div', { class: 'tpl' }, h('span', { style: css }, t.n === 'Básico' ? 'Aa' : t.n)), t.n));
  }
  openSheet('Añadir texto', grid);
}
function openTextEditor(x, tab = 'text') {
  const pane = h('div', { class: 'stack' });
  const tabs = chips([{ v: 'text', n: 'Texto' }, { v: 'style', n: 'Estilo' }, { v: 'anim', n: 'Animación' }], tab, v => { tab = v; draw(); }, 'seg');
  const label = () => { const d = divs.get(x.id); if (d) d.querySelector('.lbl').textContent = (x.text || ' ').split('\n')[0] || ' '; };
  function draw() {
    pane.innerHTML = '';
    if (tab === 'text') {
      const ta = h('textarea', { rows: 3, placeholder: 'Escribe tu texto…' }); ta.value = x.text;
      ta.addEventListener('input', () => { x.text = ta.value; label(); markDirty(); });
      ta.addEventListener('change', () => commit());
      pane.append(ta, slider('Duración en pantalla', .5, 30, .1, +x.dur.toFixed(1), v => (+v).toFixed(1) + ' s', v => { x.dur = v; layoutTimeline(); }));
      setTimeout(() => { ta.focus(); ta.select(); }, 260);
    } else if (tab === 'style') {
      pane.append(
        section('Fuente', chips(FONTS.map(f => ({ v: f.id, el: h('span', { style: `font-family:"${f.id}";font-weight:${f.w}` }, f.n) })), x.font,
          v => { x.font = v; document.fonts?.load?.(`40px "${v}"`).then(markDirty).catch(() => {}); commit(); })),
        slider('Tamaño', 16, 260, 1, x.size, v => v, v => { x.size = v; }),
        section('Color', swatches(x.color, v => { x.color = v; })),
        toggleRow('Contorno', x.stroke, v => { x.stroke = v; draw(); }),
        x.stroke && swatches(x.strokeColor, v => { x.strokeColor = v; }),
        x.stroke && slider('Grosor del contorno', 1, 20, 1, x.strokeW, v => v, v => { x.strokeW = v; }),
        toggleRow('Fondo', x.bg, v => { x.bg = v; draw(); }),
        x.bg && swatches(x.bgColor, v => { x.bgColor = v; }),
        x.bg && slider('Opacidad del fondo', 0, 100, 1, Math.round(x.bgAlpha * 100), v => v + '%', v => { x.bgAlpha = v / 100; }),
        section('Sombra', chips([{ v: 'none', n: 'Ninguna' }, { v: 'drop', n: 'Sombra' }, { v: 'glow', n: 'Brillo neón' }], x.shadow, v => { x.shadow = v; commit(); })),
        section('Posición rápida', chips([{ v: .15, n: 'Arriba' }, { v: .5, n: 'Centro' }, { v: .82, n: 'Abajo' }], null, v => { x.x = .5; x.y = v; commit(); })),
        h('p', { class: 'muted' }, 'Consejo: arrastra el texto en la vista previa para moverlo y pellizca con dos dedos para cambiar su tamaño.'));
    } else {
      pane.append(
        section('Entrada', chips(ANIM_IN, x.animIn, v => { x.animIn = v; commit(); replay(); }, 'chips wrap')),
        section('Salida', chips(ANIM_OUT, x.animOut, v => { x.animOut = v; commit(); }, 'chips wrap')));
    }
  }
  const replay = () => { curT = x.start; setScrollFromT(true); markDirty(); };
  draw();
  openSheet('Texto', tabs, pane);
}
// --- proyecto ---
function openRatio() {
  openSheet('Formato del vídeo', chips(Object.keys(RATIOS).map(r => {
    const [a, b] = RATIOS[r], k = 18 / Math.max(a, b);
    const names = { '9:16': 'TikTok / Reels', '16:9': 'YouTube', '1:1': 'Cuadrado', '4:5': 'Instagram', '3:4': 'Retrato' };
    return { v: r, el: h('span', {}, h('i', { class: 'ratio-ico', style: `width:${a * k}px;height:${b * k}px` }), `${r} · ${names[r]}`) };
  }), project.ratio, v => { project.ratio = v; resizeCanvas(); commit(); }, 'chips wrap'));
}
function openBg() {
  openSheet('Fondo',
    h('p', { class: 'muted' }, 'Se ve cuando el clip no llena todo el encuadre (modo “Ajustar”).'),
    swatches(project.bg, v => { project.bg = v; }, [{ v: 'blur', el: h('button', { class: 'sw' + (project.bg === 'blur' ? ' on' : ''), title: 'Desenfocado', style: 'background:linear-gradient(135deg,#19e3c4,#8f5cff);filter:blur(1px)' }) }]),
    h('p', { class: 'muted' }, 'El primer círculo usa una versión desenfocada del propio vídeo, como en CapCut.'));
}
function openMenu() {
  const item = (icon, label, fn, cls = '') => h('button', { class: 'menu-item ' + cls, html: ic(icon) + `<span>${label}</span>`, onclick: fn });
  openSheet('Menú',
    deferredInstall && item('install', 'Instalar la app', () => { closeSheet(false); doInstall(); }),
    item('help', 'Ayuda y atajos', openHelp),
    item('new', 'Nuevo proyecto (borrar todo)', newProjectFlow, 'danger'),
    h('p', { class: 'muted' }, 'CutLab guarda tu proyecto automáticamente en este dispositivo. Tus vídeos nunca se suben a internet.'));
}
function openHelp() {
  openSheet('Ayuda', h('div', { class: 'help', html: `
    <p><b>Línea de tiempo:</b> desliza para moverte. La línea blanca es el cursor. Pellizca para hacer zoom.</p>
    <p><b>Recortar:</b> toca un clip y arrastra las asas blancas de los lados.</p>
    <p><b>Mover / reordenar:</b> mantén pulsado un clip y arrástralo.</p>
    <p><b>Transiciones:</b> toca el botón pequeño entre dos clips.</p>
    <p><b>Texto:</b> arrástralo en la vista previa; pellizca para el tamaño; tócalo de nuevo para editar.</p>
    <p><b>Exportar:</b> se graba en tiempo real. Deja la pantalla encendida.</p>
    <p><b>Teclado:</b> <kbd>Espacio</kbd> reproducir · <kbd>S</kbd> dividir · <kbd>Supr</kbd> borrar · <kbd>Ctrl+Z</kbd>/<kbd>Ctrl+Y</kbd> deshacer/rehacer · <kbd>←</kbd><kbd>→</kbd> fotograma</p>` }));
}
async function newProjectFlow() {
  if (!confirm('¿Borrar el proyecto actual y empezar uno nuevo?')) return;
  closeSheet(false); pause();
  project = newProject(); sel = null; curT = 0;
  for (const m of media.values()) URL.revokeObjectURL(m.url);
  media.clear(); pruneEls();
  await DB.clear('media').catch(() => {}); await DB.put('kv', project, 'project').catch(() => {});
  hist = [JSON.stringify(project)]; hIdx = 0;
  resizeCanvas(); afterChange(); buildToolbar(); setScrollFromT(true);
}

// ---------- exportación ----------
let rec = null, chunks = [], wakeLock = null, expUrl = null;
function pickMime() {
  if (!window.MediaRecorder?.isTypeSupported) return '';
  return ['video/mp4;codecs=avc1.42E01E,mp4a.40.2', 'video/mp4;codecs=avc1,mp4a.40.2', 'video/mp4', 'video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm']
    .find(m => MediaRecorder.isTypeSupported(m)) || '';
}
function openExport() {
  if (totalDur() <= 0) return toast('Añade algo antes de exportar');
  if (!window.MediaRecorder || !cv.captureStream) return toast('Tu navegador no permite exportar vídeo. Prueba con Chrome.');
  let q = 1080, fps = 30;
  const mime = pickMime(), fmtName = mime.includes('mp4') ? 'MP4' : 'WebM';
  openSheet('Exportar',
    section('Resolución', chips([{ v: 480, n: '480p' }, { v: 720, n: '720p' }, { v: 1080, n: '1080p' }], q, v => { q = v; }, 'seg')),
    section('Fotogramas por segundo', chips([{ v: 24, n: '24' }, { v: 30, n: '30' }, { v: 60, n: '60' }], fps, v => { fps = v; }, 'seg')),
    h('p', { class: 'muted' }, `Formato: ${fmtName} · Duración: ${fmt(totalDur())}. La exportación tarda lo mismo que dura el vídeo.`),
    h('button', { class: 'primary', style: 'padding:14px;margin:0', html: ic('download') + 'Exportar vídeo', onclick: () => { closeSheet(false); startExport(q, fps); } }));
}
async function startExport(q, fps) {
  ensureAudio(); try { await actx?.resume(); } catch {}
  pause(); exporting = true;
  $('#exportOverlay').classList.remove('hidden'); $('#expRun').classList.remove('hidden'); $('#expDone').classList.add('hidden');
  $('#expBar').style.width = '0%'; $('#expPct').textContent = '0%';
  const [w, hh] = dims(project.ratio, q); cv.width = w; cv.height = hh;
  curT = 0; const seq = mainSeq(); syncMedia(0, seq);
  const t0 = performance.now();
  await new Promise(r => { const chk = () => { const e = seq[0], el = e && getEl(e.c); if (!el || el.tagName === 'IMG' || el.readyState >= 2 || performance.now() - t0 > 3000) r(); else setTimeout(chk, 60); }; chk(); });
  render(0, seq);
  try { wakeLock = await navigator.wakeLock?.request('screen'); } catch {}
  const tracks = [...cv.captureStream(fps).getVideoTracks()];
  if (recDest) tracks.push(...recDest.stream.getAudioTracks());
  const mime = pickMime();
  try { rec = new MediaRecorder(new MediaStream(tracks), mime ? { mimeType: mime, videoBitsPerSecond: q >= 1080 ? 10e6 : q >= 720 ? 6e6 : 3e6 } : {}); }
  catch (e) { console.warn(e); exporting = false; endExportUI(); return toast('No se pudo iniciar la exportación'); }
  chunks = [];
  rec.ondataavailable = e => e.data && e.data.size && chunks.push(e.data);
  rec.onstop = () => finishExport(mime);
  rec.start(500);
  playing = true; lastTs = performance.now(); stallStart = 0; syncMedia(0, seq); markDirty();
}
function stopExport(ok) {
  playing = false;
  for (const el of els.values()) if (el.tagName !== 'IMG') el.pause();
  if (!ok && rec) rec.onstop = null;
  if (rec && rec.state !== 'inactive') rec.stop();
  if (!ok) { exporting = false; endExportUI(); toast('Exportación cancelada'); }
}
function finishExport(mime) {
  exporting = false;
  const type = (rec?.mimeType || mime || 'video/webm').split(';')[0], ext = type.includes('mp4') ? 'mp4' : 'webm';
  const blob = new Blob(chunks, { type }); chunks = []; rec = null;
  if (expUrl) URL.revokeObjectURL(expUrl);
  expUrl = URL.createObjectURL(blob);
  const d = new Date(), name = `cutlab-${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}-${String(d.getHours()).padStart(2, '0')}${String(d.getMinutes()).padStart(2, '0')}.${ext}`;
  $('#expVideo').src = expUrl; const a = $('#expDownload'); a.href = expUrl; a.download = name;
  const share = $('#expShare');
  if (NATIVE) {
    a.removeAttribute('href'); a.onclick = ev => { ev.preventDefault(); nativeSave(blob, name, false); };
    share.classList.remove('hidden'); share.onclick = () => nativeSave(blob, name, true);
  } else {
    const file = new File([blob], name, { type });
    share.classList.toggle('hidden', !(navigator.canShare && navigator.canShare({ files: [file] })));
    share.onclick = () => navigator.share({ files: [file], title: 'Mi vídeo' }).catch(() => {});
  }
  $('#expRun').classList.add('hidden'); $('#expDone').classList.remove('hidden');
  resizeCanvas(); releaseWake(); $('#btnPlay').innerHTML = ic('play');
}
// ---------- app nativa de Android (Capacitor) ----------
const NATIVE = !!(window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform());
const savedPaths = new WeakMap();
async function blobToB64Chunks(blob, onChunk) {
  const CH = 3 * 1024 * 1024; // múltiplo de 3 para que el base64 se pueda concatenar
  for (let o = 0; o < blob.size; o += CH) {
    const b64 = await new Promise((res, rej) => {
      const r = new FileReader(); r.onload = () => res(String(r.result).split(',')[1] || ''); r.onerror = rej; r.readAsDataURL(blob.slice(o, o + CH));
    });
    await onChunk(b64, o === 0);
  }
}
async function nativeSave(blob, name, share) {
  const P = window.Capacitor.Plugins, FS = P.Filesystem;
  if (!FS) return toast('No se pudo guardar');
  try {
    let uri = savedPaths.get(blob);
    if (!uri) {
      toast('Guardando…');
      const write = async dir => {
        const path = dir === 'DOCUMENTS' ? 'CutLab/' + name : name;
        await blobToB64Chunks(blob, (data, first) => first
          ? FS.writeFile({ path, data, directory: dir, recursive: true })
          : FS.appendFile({ path, data, directory: dir }));
        return (await FS.getUri({ path, directory: dir })).uri;
      };
      try { uri = await write('DOCUMENTS'); toast('Guardado en Documentos/CutLab'); }
      catch (e) { console.warn(e); uri = await write('CACHE'); if (!share) share = true; }
      savedPaths.set(blob, uri);
    } else if (!share) toast('Ya está guardado en Documentos/CutLab');
    if (share && P.Share) await P.Share.share({ title: 'Mi vídeo', files: [uri], dialogTitle: 'Compartir o guardar vídeo' }).catch(() => {});
  } catch (e) { console.warn(e); toast('No se pudo guardar el vídeo'); }
}
if (NATIVE) document.documentElement.classList.add('native');

function endExportUI() { $('#exportOverlay').classList.add('hidden'); resizeCanvas(); releaseWake(); $('#btnPlay').innerHTML = ic('play'); markDirty(); }
function releaseWake() { try { wakeLock?.release(); } catch {} wakeLock = null; }
$('#expCancel').onclick = () => stopExport(false);
$('#expClose').onclick = () => { $('#expVideo').pause(); $('#exportOverlay').classList.add('hidden'); curT = 0; setScrollFromT(true); markDirty(); };

// ---------- instalación (PWA) ----------
let deferredInstall = null;
window.addEventListener('beforeinstallprompt', e => { e.preventDefault(); deferredInstall = e; $('#btnInstall').classList.remove('hidden'); });
window.addEventListener('appinstalled', () => { deferredInstall = null; $('#btnInstall').classList.add('hidden'); toast('¡CutLab instalado!'); });
async function doInstall() {
  if (!deferredInstall) return;
  deferredInstall.prompt(); try { await deferredInstall.userChoice; } catch {}
  deferredInstall = null; $('#btnInstall').classList.add('hidden');
}
$('#btnInstall').onclick = doInstall;
if ('serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === 'localhost')) {
  window.addEventListener('load', () => navigator.serviceWorker.register('sw.js').catch(() => {}));
}

// ---------- eventos globales ----------
$('#btnUndo').innerHTML = ic('undo'); $('#btnRedo').innerHTML = ic('redo'); $('#btnMenu').innerHTML = ic('dots');
$('#btnPlay').innerHTML = ic('play'); $('#zoomIn').innerHTML = ic('plus'); $('#zoomOut').innerHTML = ic('minus');
$('#sheetClose').innerHTML = ic('check'); $('#emptyAdd').innerHTML = ic('plus');
$('#btnUndo').onclick = undo; $('#btnRedo').onclick = redo; $('#btnMenu').onclick = openMenu;
$('#btnPlay').onclick = togglePlay; $('#btnExport').onclick = openExport;
$('#zoomIn').onclick = () => setPps(pps * 1.4); $('#zoomOut').onclick = () => setPps(pps / 1.4);
$('#sheetClose').onclick = () => closeSheet(); $('#scrim').onclick = () => closeSheet();
$('#emptyAdd').onclick = () => $('#fileMedia').click();
$('#fileMedia').onchange = e => { importFiles(e.target.files); e.target.value = ''; };
$('#fileAudio').onchange = e => { importFiles(e.target.files, true); e.target.value = ''; };
document.addEventListener('pointerdown', ensureAudio, { once: true, capture: true });
document.addEventListener('dragover', e => e.preventDefault());
document.addEventListener('drop', e => { e.preventDefault(); if (e.dataTransfer?.files?.length) importFiles(e.dataTransfer.files); });
document.addEventListener('visibilitychange', () => { if (document.hidden && playing && !exporting) pause(); });
document.addEventListener('keydown', e => {
  if (exporting || e.target.closest('input,textarea')) return;
  const k = e.key.toLowerCase(), mod = e.ctrlKey || e.metaKey;
  if (k === ' ') { e.preventDefault(); togglePlay(); }
  else if (mod && k === 'z') { e.preventDefault(); e.shiftKey ? redo() : undo(); }
  else if (mod && k === 'y') { e.preventDefault(); redo(); }
  else if (k === 's' && !mod) splitAtPlayhead();
  else if ((k === 'delete' || k === 'backspace') && sel) { e.preventDefault(); deleteSel(); }
  else if (k === 'arrowleft' || k === 'arrowright') { e.preventDefault(); if (playing) pause(); curT = clamp(curT + (k === 'arrowleft' ? -1 : 1) / 30, 0, totalDur()); markDirty(); }
  else if (k === 'escape') { if (!$('#sheet').classList.contains('closed')) closeSheet(); else if (sel) select(null); }
});
new ResizeObserver(fitCanvas).observe($('#stage'));
new ResizeObserver(() => { layoutTimeline(); setScrollFromT(true); }).observe(tl);

// ---------- arranque ----------
(async function init() {
  try {
    const p = await DB.get('kv', 'project');
    if (p && p.v === 1) {
      const ids = new Set([...p.main.map(c => c.mediaId), ...p.audios.map(a => a.mediaId)]);
      for (const id of ids) {
        const r = await DB.get('media', id).catch(() => null);
        if (r?.blob) media.set(id, { ...r, url: URL.createObjectURL(r.blob) });
      }
      p.main = p.main.filter(c => media.has(c.mediaId)); p.audios = p.audios.filter(a => media.has(a.mediaId));
      project = p;
    }
  } catch (e) { console.warn('Sin almacenamiento local', e); }
  hist = [JSON.stringify(project)]; hIdx = 0;
  resizeCanvas(); buildTimeline(); buildToolbar(); updateUndo(); updateEmpty();
  for (const f of FONTS) document.fonts?.load?.(`${f.w} 40px "${f.id}"`).then(markDirty).catch(() => {});
  setScrollFromT(true);
  requestAnimationFrame(tick);
})();
