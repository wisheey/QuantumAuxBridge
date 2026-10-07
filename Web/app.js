'use strict';
const $ = id => document.getElementById(id);
let code = '', state = null, epoch = 0, locked = false, selectedGroup = 'All', online = false;
const strips = new Map(), queues = new Map();
let errorTimer;
function error(message) {
  $('error').textContent = message; $('error').hidden = false;
  clearTimeout(errorTimer); errorTimer = setTimeout(() => $('error').hidden = true, 5500);
}
async function api(path, payload, access = code) {
  const response = await fetch(path, {method: payload ? 'POST' : 'GET', cache: 'no-store',
    headers: {'Authorization': `Bearer ${access}`, ...(payload ? {'Content-Type': 'application/json'} : {})},
    body: payload ? JSON.stringify(payload) : undefined, signal: AbortSignal.timeout(5000)});
  const result = await response.json();
  if (!response.ok) { const failure = new Error(result.error || 'Connection failed'); failure.status = response.status; throw failure; }
  return result;
}
function dbText(value) { return value == null ? '—' : value <= -140 ? '−∞ dB' : `${value > 0 ? '+' : ''}${value.toFixed(2)} dB`; }
function sliderDb(value) { return Math.max(-50, Math.min(10, value)); }
function channelName(ch) { return ch.name === null ? `Input ${ch.id} · waiting for name` : ch.name || '(unnamed on console)'; }
function panText(value) { return value == null ? 'PAN —' : Math.abs(value - .5) < .015 ? 'CENTER' : `${Math.round(Math.abs(value - .5) * 200)} ${value < .5 ? 'LEFT' : 'RIGHT'}`; }
function el(tag, cls, text) {
  const node = document.createElement(tag); if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text; return node;
}
function drawFader(obj, value) {
  const position = value == null ? 0 : Math.max(0, Math.min(100, (Math.max(-50, value) + 50) / (Number(obj.level.max) + 50) * 100));
  obj.card.style.setProperty('--position', `${position}%`);
  obj.card.classList.toggle('unsynced', value == null);
  obj.level.setAttribute('aria-valuetext', dbText(value));
}
function build(data) {
  strips.clear(); $('channels').replaceChildren(); $('groups').replaceChildren();
  $('mixname').textContent = data.aux.name === null ? `Aux ${data.aux.id} · waiting for name` : data.aux.name || '(unnamed on console)';
  $('auxlabel').textContent = `AUX ${data.aux.id} · ${data.aux.stereo ? 'STEREO' : 'MONO'}`;
  $('ceiling').textContent = `Range −50 to +${data.max_db} dB`;
  $('show-pan').disabled = !data.aux.stereo;
  $('groups').hidden = new Set(data.channels.map(c => c.group || 'Inputs')).size <= 1;
  for (const group of ['All', ...new Set(data.channels.map(c => c.group || 'Inputs'))]) {
    const button = el('button', group === 'All' ? 'selected' : '', group);
    button.onclick = () => {selectedGroup = group; for (const b of $('groups').children) b.classList.toggle('selected', b === button); filter();};
    $('groups').append(button);
  }
  for (const ch of data.channels) {
    const card = el('article', 'strip'), number = el('div', 'number', `CH ${ch.id}`);
    const title = el('h2', '', channelName(ch)), readout = el('div', 'readout', '—'), hint = el('div', 'fieldhint', 'Waiting for console');
    const level = el('input', 'fader'); level.type = 'range'; level.min = -50; level.max = data.max_db; level.step = .5;
    level.setAttribute('aria-label', `${ch.name} send level to ${data.aux.name}`);
    const shell = el('div', 'fader-shell'), well = el('div', 'fader-well');
    const fill = el('div', 'fader-fill'), ticks = el('div', 'fader-ticks'), cap = el('div', 'fader-cap');
    for (const value of [10, 0, -10, -20, -30, -40, -50]) {
      const tick = el('span', value % 20 === 0 ? 'major' : '');
      tick.style.bottom = `${(value + 50) / (data.max_db + 50) * 100}%`;
      tick.setAttribute('aria-hidden', 'true'); ticks.append(tick);
    }
    well.append(fill, ticks, cap); shell.append(well, level);
    const labelPlate = el('div', 'label-plate'), labelRow = el('div', 'label-row');
    const obj = {ch, card, title, readout, hint, level, dragging: false, waiting: {}};
    card.style.setProperty('--strip-bright', '#265aee');
    card.style.setProperty('--strip-dark', '#17298a');
    labelRow.append(number); labelPlate.append(labelRow, title);
    card.append(readout, shell, hint, labelPlate);
    // Use the visible well's geometry, not the browser's invisible native thumb.
    // Pointer capture keeps a finger attached even when it leaves the strip.
    let activePointer = null, grabOffset = 0;
    function updateLevel() {
      const value = sliderDb(Number(level.value));
      drawFader(obj, value); readout.textContent = dbText(value);
      schedule(obj, 'level', value);
    }
    function movePointer(event) {
      if (event.pointerId !== activePointer || level.disabled) return;
      const rect = well.getBoundingClientRect();
      if (!rect.height) return;
      const fraction = Math.max(0, Math.min(1, (rect.bottom - event.clientY + grabOffset) / rect.height));
      const min = Number(level.min), max = Number(level.max), step = Number(level.step);
      level.value = Math.max(min, Math.min(max, min + Math.round(fraction * (max - min) / step) * step));
      updateLevel();
    }
    level.addEventListener('pointerdown', event => {
      if (level.disabled || activePointer !== null || event.button > 0) return;
      event.preventDefault(); level.focus({preventScroll: true});
      activePointer = event.pointerId; obj.dragging = true;
      const rect = well.getBoundingClientRect();
      const center = rect.bottom - (Number(level.value) + 50) / (Number(level.max) + 50) * rect.height;
      // Grabbing the handle preserves its value; tapping the track moves to it.
      grabOffset = Math.abs(event.clientY - center) <= 22 ? event.clientY - center : 0;
      level.setPointerCapture(event.pointerId);
      movePointer(event);
    });
    level.addEventListener('pointermove', event => {
      if (event.pointerId === activePointer) { event.preventDefault(); movePointer(event); }
    });
    function release(event) {
      if (activePointer === null || (event.pointerId != null && event.pointerId !== activePointer)) return;
      if (event.type === 'pointerup') movePointer(event);
      const pointer = activePointer; activePointer = null; obj.dragging = false;
      if (level.hasPointerCapture(pointer)) level.releasePointerCapture(pointer);
    }
    level.addEventListener('pointerup', release);
    level.addEventListener('pointercancel', release);
    level.addEventListener('lostpointercapture', release);
    level.addEventListener('blur', release);
    level.oninput = updateLevel; // Preserve native keyboard and assistive controls.
    level.onchange = updateLevel;
    if (data.aux.stereo) {
      const box = el('div', 'panbox'), label = el('label', '', 'PAN —'), pan = el('input', 'pan');
      pan.type = 'range'; pan.min = 0; pan.max = 1; pan.step = .01;
      pan.setAttribute('aria-label', `${ch.name} aux send pan`);
      pan.oninput = () => {label.textContent = panText(Number(pan.value)); schedule(obj, 'pan', Number(pan.value));};
      box.append(label, pan); card.append(box); obj.pan = pan; obj.panLabel = label;
    }
    strips.set(ch.id, obj); $('channels').append(card);
  }
  filter();
}
function filter() {
  const query = $('search').value.toLowerCase();
  for (const obj of strips.values()) obj.card.hidden =
    (selectedGroup !== 'All' && (obj.ch.group || 'Inputs') !== selectedGroup) || !`${obj.ch.id} ${obj.ch.name}`.toLowerCase().includes(query);
}
function paint(data) {
  let fresh = 0;
  $('mixname').textContent = data.aux.name === null ? `Aux ${data.aux.id} · waiting for name` : data.aux.name || '(unnamed on console)';
  for (const ch of data.channels) {
    const obj = strips.get(ch.id); obj.ch = ch; obj.title.textContent = channelName(ch);
    obj.level.setAttribute('aria-label', `${channelName(ch)} send level`);
    const namesReady = ch.name !== null && data.aux.name !== null && data.aux.supported;
    for (const field of ['level', 'pan']) {
      const cell = ch.fields[field], waiting = obj.waiting[field];
      if (waiting && cell.value != null && Math.abs(cell.value - waiting.value) < .004) delete obj.waiting[field];
      else if (waiting && Date.now() - waiting.at > 5500) {
        delete obj.waiting[field]; error(`${ch.name}: change not confirmed by the console.`);
      }
    }
    if (namesReady && ch.fields.level.fresh && ch.fields.level.value != null) fresh++;
    const pending = Object.keys(obj.waiting).length > 0;
    obj.hint.textContent = pending ? 'Awaiting confirmation…' : ch.fields.level.value == null ? 'Waiting for console' : !ch.fields.level.fresh ? 'Feedback stale · paused' : !namesReady ? 'Waiting for console names' : 'Console send level';
    if (!obj.dragging && !obj.waiting.level && !queues.get(`${ch.id}/level`)?.next) { obj.level.value = Math.max(-50, Math.min(ch.fields.level.value ?? -50, data.max_db)); obj.readout.textContent = dbText(ch.fields.level.value); drawFader(obj, ch.fields.level.value); }
    obj.card.classList.toggle('paused', locked || !online || !namesReady || !ch.fields.level.fresh);
    obj.level.disabled = locked || !online || !namesReady || !ch.fields.level.fresh || ch.fields.level.value == null;
    if (obj.pan) {
      obj.pan.disabled = locked || !online || !namesReady || !ch.fields.pan.fresh || ch.fields.pan.value == null;
      if (!obj.waiting.pan) {obj.pan.value = ch.fields.pan.value ?? .5; obj.panLabel.textContent = panText(ch.fields.pan.value);}
    }
  }
  $('status').textContent = !data.connection.connected ? '● CONSOLE OFFLINE' : `● LIVE · ${fresh}/${data.channels.length} SENDS`;
  $('notice').textContent = data.connection.connected && fresh === data.channels.length && data.channels.length ? 'Changes apply only to this aux. Console feedback confirms each change.' : data.connection.message + ' Unsynced controls stay paused.';
  filter();
  document.body.classList.toggle('locked', locked);
  if (!online) {
    $('status').textContent = '● BRIDGE OFFLINE';
    $('notice').textContent = 'Connection lost. Controls paused; changes will not replay on reconnect.';
  }
}
function schedule(obj, field, value) {
  if (locked || !online || !code) return;
  const key = `${obj.ch.id}/${field}`;
  let queue = queues.get(key);
  if (!queue) {queue = {busy: false, next: null, timer: null}; queues.set(key, queue);}
  queue.next = {channel: obj.ch.id, field, value, revision: state.revision};
  clearTimeout(queue.timer);
  queue.timer = setTimeout(() => flush(queue, obj, epoch, code), 110);
}
async function flush(queue, obj, myEpoch, myCode) {
  if (queue.busy || !queue.next || myEpoch !== epoch || locked || !online) return;
  queue.busy = true;
  const payload = queue.next; queue.next = null;
  obj.waiting[payload.field] = {value: payload.value, at: Date.now()};
  try { await api('/api/send', payload, myCode); }
  catch (e) {if (myEpoch === epoch) {delete obj.waiting[payload.field]; error(e.message);}}
  finally {
    queue.busy = false;
    if (queue.next && myEpoch === epoch) queue.timer = setTimeout(() => flush(queue, obj, myEpoch, myCode), 110);
  }
}
async function refresh() {
  if (!code) return;
  const myEpoch = epoch;
  try {
    const data = await api('/api/state');
    if (myEpoch !== epoch) return;
    online = true;
    const changed = !state || (state.revision !== data.revision || state.aux.stereo !== data.aux.stereo || state.channels.map(c=>c.id).join(',') !== data.channels.map(c=>c.id).join(','));
    if (changed) {
      for (const q of queues.values()) clearTimeout(q.timer); queues.clear();
      if (state && state.revision !== data.revision) { epoch++; locked = true; $('lock').textContent = 'Unlock controls'; error('Console session changed. Check the aux and channel names before unlocking.'); }
      build(data);
    }
    state = data; paint(data); $('login').hidden = true; $('mixer').hidden = false;
  } catch (e) {
    if (myEpoch !== epoch) return;
    if (e.status === 403) { resetSession(); error(e.message); return; }
    online = false;
    for (const q of queues.values()) {clearTimeout(q.timer); q.next = null;}
    for (const obj of strips.values()) {obj.dragging = false; obj.level.disabled = true; if(obj.pan) obj.pan.disabled = true;}
    $('status').textContent = '● BRIDGE OFFLINE'; $('notice').textContent = 'Connection lost. Controls paused; changes will not replay on reconnect.';
  }
}
async function join(value) {
  const myEpoch = ++epoch;
  try {
    const data = await api('/api/state', null, value);
    if (myEpoch !== epoch) return;
    code = value; online = true; state = data; selectedGroup = 'All'; locked = false;
    $('lock').textContent = 'Lock controls'; $('search').value = '';
    build(data); paint(data); $('login').hidden = true; $('mixer').hidden = false;
  } catch(e) {if (e.status === 403) resetSession(); error(e.message);}
}
let claiming = false;
async function claimMix(aux) {
  if (claiming || code) return; claiming = true;
  try {
    const lease = await api('/api/claim', {aux}, '');
    code = lease.token; try { sessionStorage.setItem('quantum-session', code); } catch {}
    await join(code);
  } catch(e) { error(e.message); }
  finally { claiming = false; if (!code) await loadMixes(); }
}
async function loadMixes() {
  if (code || claiming) return;
  try {
    const result = await api('/api/mixes', null, '');
    if (code || claiming) return;
    $('mix-status').textContent = result.auxes.length ? 'Select a free mix. Mixes in use are reserved.' : result.connection.message;
    $('mix-list').replaceChildren();
    for (const aux of result.auxes) {
      const button = el('button', 'mix-choice');
      const name = aux.name === null ? 'Waiting for name' : aux.name || '(unnamed on console)';
      const detail = aux.occupied ? 'IN USE' : aux.available ? 'AVAILABLE' : 'NOT READY';
      button.append(el('span', '', `Aux ${aux.id} · ${name}`), el('small', '', detail));
      button.disabled = !aux.available; button.onclick = () => claimMix(aux.id);
      $('mix-list').append(button);
    }
  } catch(e) { $('mix-status').textContent = 'Cannot reach the bridge. Retrying…'; }
}
$('search').oninput = () => { filter(); $('channels').scrollLeft = 0; };
$('show-pan').onclick = () => { const shown = $('show-pan').getAttribute('aria-pressed') !== 'true'; $('show-pan').setAttribute('aria-pressed', String(shown)); $('mixer').classList.toggle('pan-open', shown); };
$('bank-prev').onclick = () => $('channels').scrollBy({left: -$('channels').clientWidth, behavior: 'smooth'});
$('bank-next').onclick = () => $('channels').scrollBy({left: $('channels').clientWidth, behavior: 'smooth'});
$('lock').onclick = () => {
  locked = !locked; $('lock').textContent = locked ? 'Unlock controls' : 'Lock controls';
  if (locked) for (const q of queues.values()) {clearTimeout(q.timer); q.next = null;}
  paint(state);
};
function resetSession() {
  epoch++; code = ''; state = null; online = false;
  try { sessionStorage.removeItem('quantum-session'); } catch {}
  for (const q of queues.values()) clearTimeout(q.timer); queues.clear();
  $('mixer').hidden = true; $('login').hidden = false; document.body.classList.remove('locked');
}
$('leave').onclick = async () => {
  const previous = code;
  resetSession();
  try { await api('/api/release', {}, previous); } catch { error('Connection lost. This mix will become free after 30 seconds without contact.'); }
  await loadMixes();
};
// A private reservation token is automatic. No user-entered access code is used.
try { code = sessionStorage.getItem('quantum-session') || ''; } catch {}
async function refreshLoop() { if (code) await refresh(); else await loadMixes(); setTimeout(refreshLoop, 1000); }
refreshLoop();
