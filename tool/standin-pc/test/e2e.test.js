// End to end: starts `index.js` (room server + stand-in PC) as a child process, then a scripted phone pairs through the
// room server, sends commands, browses, watches, reads a few MiB of the video over media-v1 and checks them against the
// file, and links again after the stand-in restarts (through the room server and its home-network socket).
//
// The video: $STANDIN_VIDEO, else a made-up 6 MiB file in the temp folder.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, openSync, readSync, closeSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import nodeDataChannel from 'node-datachannel';
import { ScriptedPhone } from './phone.js';
import { randomHex } from '../lib/signing.js';

const here = dirname(fileURLToPath(import.meta.url));
const work = mkdtempSync(join(tmpdir(), 'standin-pc-test-'));
const statePath = join(work, 'state.json');
const logPath = join(work, 'standin.log');

function findVideo() {
  if (process.env.STANDIN_VIDEO) return process.env.STANDIN_VIDEO;
  const made = join(work, 'made-up.mkv');
  writeFileSync(made, randomBytes(6 * 1024 * 1024));
  return made;
}
const videoPath = findVideo();
const videoSize = statSync(videoPath).size;

function fileBytes(offset, count) {
  const fd = openSync(videoPath, 'r');
  const buffer = Buffer.alloc(count);
  const read = readSync(fd, buffer, 0, count, offset);
  closeSync(fd);
  return buffer.subarray(0, read);
}

/** Starts the CLI; resolves once it has printed its port, LAN port and pairing link. */
function startStandin() {
  const child = spawn(process.execPath, [join(here, '..', 'index.js'), '--video', videoPath, '--port', '0', '--state', statePath, '--log', logPath, '--lan-port', '47870', '--high-water', '65536'], {
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  let out = '';
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`The stand-in didn't start:\n${out}`)), 15000);
    const check = () => {
      const port = out.match(/server: listening .* port=(\d+)/)?.[1];
      const lanPort = out.match(/lan: started port=(\d+)/)?.[1];
      const link = out.match(/blackpearl:\/\/pair\?\S+/)?.[0];
      const ready = /room server ready/.test(out);
      if (port && link && ready) {
        clearTimeout(timer);
        resolve({ child, port: Number(port), lanPort: lanPort ? Number(lanPort) : null, link: new URL(link), output: () => out });
      }
    };
    child.stdout.on('data', (data) => {
      out += data;
      check();
    });
    child.stderr.on('data', (data) => (out += data));
    child.on('exit', (code) => reject(new Error(`The stand-in exited (${code}):\n${out}`)));
  });
}

async function stopStandin(standin) {
  const exited = new Promise((resolve) => standin.child.once('exit', resolve));
  standin.child.stdin.write('quit\n');
  await exited;
}

const phones = [];
let standin = null;
after(async () => {
  for (const phone of phones) phone.close();
  if (standin && standin.child.exitCode === null) await stopStandin(standin);
  nodeDataChannel.cleanup();
});

const say = (line) => console.log(`  · ${line}`);

test('a scripted phone pairs, controls, browses, watches and reads the video over media-v1', { timeout: 180000 }, async () => {
  say(`video: ${videoPath} (${(videoSize / 1048576).toFixed(1)} MiB)`);
  standin = await startStandin();
  const { link } = standin;
  const pcId = link.searchParams.get('pc');
  const code = link.searchParams.get('code');
  const server = new URL(link.searchParams.get('server'));
  assert.equal(server.hostname, '10.0.2.2', 'the link points the emulator at this computer');
  assert.equal(Number(server.port), standin.port);
  const socketUrl = `ws://127.0.0.1:${standin.port}/remote`;
  say(`room server on port ${standin.port}, home-network socket on ${standin.lanPort}, PC ${pcId}`);

  const health = await (await fetch(`http://127.0.0.1:${standin.port}/health`)).json();
  assert.equal(health.remote, 1);

  // Pairing through the room server.
  const phone = new ScriptedPhone({ socketUrl, pcId, phone: 'pair', key: code });
  phones.push(phone);
  const welcome = await phone.connect();
  assert.equal(phone.presence.type, 'remote-online');
  assert.deepEqual(welcome.settings, { iceServers: [], forceRelay: false });
  assert.deepEqual(await phone.link(), { linked: true });
  say('linked with the pairing code');
  phone.send({ type: 'hello', protocol: 1, app: '0.0.0-test', device: 'Scripted phone' });
  const hello = await phone.next('welcome');
  assert.equal(hello.pcId, pcId);
  assert.deepEqual([...hello.features].sort(), ['library', 'mark-watched', 'queues', 'unwatched', 'watch']);
  assert.equal(hello.lan?.port, standin.lanPort);
  phone.send({ type: 'pair', name: 'Scripted phone' });
  const paired = await phone.next('paired');
  assert.match(paired.phoneId, /^[0-9a-f]{32}$/);
  assert.match(paired.secret, /^[0-9a-f]{64}$/);
  let state = await phone.next('state');
  assert.equal(state.media, true);
  say(`paired as ${paired.phoneId.slice(0, 8)}; the PC plays "${state.title}" (${state.detail})`);

  // The used code, and a phone the PC doesn't know, get their hints.
  const late = new ScriptedPhone({ socketUrl, pcId, phone: 'pair', key: code });
  phones.push(late);
  await late.connect();
  assert.deepEqual(await late.link(), { rejected: 'pairing-expired' });
  const stranger = new ScriptedPhone({ socketUrl, pcId, phone: randomHex(16), key: randomHex(32) });
  phones.push(stranger);
  await stranger.connect();
  assert.deepEqual(await stranger.link(), { rejected: 'unknown-phone' });
  late.close();
  stranger.close();
  say('a used code got pairing-expired, an unknown phone got unknown-phone');

  // Commands change the made-up state; each is answered with a fresh state.
  phone.send({ type: 'command', action: 'toggle' });
  state = await phone.next('state');
  assert.equal(state.playing, false);
  phone.send({ type: 'command', action: 'volume', value: 30 });
  state = await phone.next('state');
  assert.equal(state.volume, 30);
  phone.send({ type: 'command', action: 'next' });
  state = await phone.next('state');
  assert.equal(state.detail, 'Season 1 · Episode 4 · Low Tide');
  say(`commands: toggle → playing=${false}, volume → 30, next → ${state.detail}`);

  // Browsing.
  const home = await phone.ask({ type: 'browse', home: true, category: 0, query: '', parentId: null, season: null, page: 0, seed: 7 });
  assert.equal(home.type, 'page');
  const sections = [...new Set(home.entries.map((e) => e.homeSection))];
  for (const section of ['continue', 'suggestions', 'mystery', 'unwatched']) assert.ok(sections.includes(section), `Home has ${section}`);
  const shows = await phone.ask({ type: 'browse', home: false, category: 2, query: '', parentId: null, season: null, page: 0, seed: 0 });
  const nightSignal = shows.entries.find((e) => e.title === 'Night Signal');
  assert.equal(nightSignal.level, 'series');
  const seasons = await phone.ask({ type: 'browse', home: false, category: 0, query: '', parentId: nightSignal.id, season: null, page: 0, seed: 0 });
  assert.deepEqual(seasons.entries.map((e) => [e.level, e.season]), [['season', 1], ['season', 2]]);
  const episodes = await phone.ask({ type: 'browse', home: false, category: 0, query: '', parentId: nightSignal.id, season: 2, page: 0, seed: 0 });
  assert.equal(episodes.entries.length, 5);
  assert.ok(episodes.entries.every((e) => e.playable && e.level === 'episode'));
  const queues = await phone.ask({ type: 'queues' });
  assert.equal(queues.queues.length, 2);
  const evening = await phone.ask({ type: 'browse', home: false, category: 0, query: '', parentId: null, season: null, page: 0, seed: 0, queue: queues.queues[0].id });
  assert.deepEqual(evening.entries.map((e) => e.index), [0, 1, 3, 4], 'a queued video the library lacks keeps its place but is not listed');
  const unwatched = await phone.ask({ type: 'browse', home: false, category: 0, query: '', parentId: null, season: null, page: 0, seed: 0, unwatched: true });
  assert.equal(unwatched.location, 'Unwatched');
  const missing = await phone.ask({ type: 'browse', home: false, category: 0, query: '', parentId: 'nope', season: null, page: 0, seed: 0 });
  assert.deepEqual([missing.type, missing.code], ['error', 'browse']);
  say(`browsed: Home (${home.entries.length} entries: ${sections.join(', ')}), Shows (${shows.total}), ${seasons.total} seasons, ${episodes.total} episodes, ${queues.queues.length} queues, Unwatched (${unwatched.total})`);

  // Watched marks.
  const film = home.entries.find((e) => e.level === 'movie' && e.playable && e.homeSection !== 'continue');
  assert.equal((await phone.ask({ type: 'mark-watched', id: film.id, level: 'movie', watched: true })).type, 'done');
  assert.equal((await phone.ask({ type: 'mark-watched', id: film.id, level: 'shelf', watched: true })).code, 'invalid');
  assert.equal((await phone.ask({ type: 'mark-watched', id: nightSignal.id, level: 'season', season: 1, watched: true })).type, 'done');

  // Watching: the file itself, read over media-v1.
  const stream = await phone.ask({ type: 'watch', id: episodes.entries[1].id, quality: 'auto', network: 'home', takeOver: false, audio: null });
  assert.equal(stream.type, 'stream');
  assert.equal(stream.kind, 'file');
  assert.equal(stream.length, videoSize);
  assert.equal(stream.resource, `file/${episodes.entries[1].id}`);
  assert.equal(stream.previous.id, episodes.entries[0].id);
  assert.equal(stream.next.id, episodes.entries[2].id);
  say(`watching ${stream.title} ${stream.detail}: ${stream.resource}, ${stream.length} bytes ${stream.extension}`);

  const start = Math.min(1024 * 1024, Math.max(0, videoSize - 5 * 1024 * 1024));
  const want = Math.min(4 * 1024 * 1024, videoSize - start);
  const chunk = 262144;
  const began = Date.now();
  const results = [];
  for (let at = 0; at < want; at += chunk * 8) {
    const window = [];
    for (let i = 0; i < 8 && at + i * chunk < want; i++) window.push(phone.read(stream.resource, start + at + i * chunk, Math.min(chunk, want - at - i * chunk)).promise);
    results.push(...(await Promise.all(window)));
  }
  const got = Buffer.concat(results.map((r) => r.bytes));
  const seconds = (Date.now() - began) / 1000;
  assert.equal(got.length, want);
  assert.ok(got.equals(fileBytes(start, want)), 'the bytes match the file');
  assert.ok(results.every((r) => r.resourceLength === videoSize));
  assert.ok(phone.largestFrame <= 16 * 1024, 'frames carry at most 16 KiB');
  say(`read ${(want / 1048576).toFixed(1)} MiB of ${stream.resource} from offset ${start} in ${results.length} reads / ${phone.framesSeen} frames (${(want / 1048576 / seconds).toFixed(1)} MiB/s): bytes match the file`);

  // 48 reads at once (12 MiB queued on the PC): answered in order, and the PC's send buffer stays bounded (the
  // media summary in the log reports the most it had buffered).
  const burstStart = Math.max(0, Math.min(64 * 1024 * 1024, videoSize - 48 * chunk));
  const burstBegan = Date.now();
  const order = [];
  const burst = [];
  for (let i = 0; i < 48; i++) {
    const read = phone.read(stream.resource, burstStart + i * chunk, chunk);
    burst.push(read.promise.then((r) => (order.push(i), r)));
  }
  const burstBytes = Buffer.concat((await Promise.all(burst)).map((r) => r.bytes));
  assert.ok(burstBytes.equals(fileBytes(burstStart, burstBytes.length)), 'the burst matches the file');
  assert.deepEqual(order, [...order].sort((a, b) => a - b), 'reads are answered in the order they were asked');
  say(`a burst of 48 reads (${(burstBytes.length / 1048576).toFixed(0)} MiB from offset ${burstStart}) came back in order in ${Date.now() - burstBegan} ms: bytes match the file`);

  const tail = await phone.read(stream.resource, videoSize - 1000, chunk).promise;
  assert.equal(tail.bytes.length, 1000);
  assert.ok(tail.bytes.equals(fileBytes(videoSize - 1000, 1000)));
  const past = await phone.read(stream.resource, videoSize + 10, 100).promise;
  assert.equal(past.bytes?.length ?? 0, 0);
  await assert.rejects(phone.read(stream.resource, 0, 0).promise, { code: 'invalid' });
  await assert.rejects(phone.read(`file/${film.id}`, 0, 100).promise, { code: 'gone' });
  await assert.rejects(phone.read('stream/abc/0', 0, 100).promise, { code: 'gone' });
  const art = await phone.read(`art/${film.artwork}/200`, 0, chunk).promise;
  assert.equal(art.bytes.readUInt16BE(0), 0xffd8);
  assert.equal(art.bytes.readUInt16BE(art.bytes.length - 2), 0xffd9);
  assert.equal(art.resourceLength, art.bytes.length);
  say(`the end of the file came short (1000 bytes), past it 0 bytes; art/${film.artwork}/200 is a ${art.bytes.length}-byte JPEG; bad reads got invalid/gone`);

  // More than 64 waiting reads: the rest are busy. Then cancel what's left; a new read still comes promptly.
  const flood = [];
  const outcomes = [];
  for (let i = 0; i < 72; i++) flood.push(phone.read(stream.resource, (i * chunk) % Math.max(1, videoSize - chunk), chunk));
  const firstBusy = new Promise((resolve) => {
    for (const read of flood) read.promise.then(() => outcomes.push('ok'), (e) => (outcomes.push(e.code), e.code === 'busy' && resolve()));
  });
  await firstBusy;
  const pending = flood.filter((r) => phone.reads.has(r.id));
  for (const read of pending) phone.cancel(read);
  const settled = Date.now();
  const fresh = await phone.read(stream.resource, 0, 4096).promise;
  assert.ok(fresh.bytes.equals(fileBytes(0, 4096)));
  const busy = outcomes.filter((o) => o === 'busy').length;
  assert.ok(busy >= 1, 'reads past 64 are busy');
  assert.ok(pending.length > 0, 'some reads were still waiting to be cancelled');
  say(`flood of 72 reads: ${busy} busy; cancelled the ${pending.length} still waiting; a new read then took ${Date.now() - settled} ms`);

  // Progress, then playing it on the PC.
  phone.send({ type: 'progress', id: stream.id, positionMs: 120000, durationMs: stream.durationMs, ended: false, final: true });
  const played = await phone.ask({ type: 'play', id: stream.id, positionMs: 120000 });
  assert.equal(played.type, 'done');
  state = await phone.next((m) => m.type === 'state' && m.mediaId === stream.id);
  assert.ok(state.positionMs >= 120000);
  const after = await phone.ask({ type: 'browse', home: true, category: 0, query: '', parentId: null, season: null, page: 0, seed: 7 });
  assert.ok(after.entries.some((e) => e.homeSection === 'continue' && e.id === stream.id && e.positionMs === 120000), 'Continue watching has the reported position');
  say(`progress saved; play → done, the PC now plays ${state.mediaId} from ${state.positionMs} ms`);
  phone.close();

  // Restart the stand-in with the same state file: the paired phone links again, through the room server and through
  // the home-network socket.
  await stopStandin(standin);
  standin = await startStandin();
  const again = new ScriptedPhone({ socketUrl: `ws://127.0.0.1:${standin.port}/remote`, pcId, phone: paired.phoneId, key: paired.secret });
  phones.push(again);
  await again.connect();
  assert.deepEqual(await again.link(), { linked: true });
  again.send({ type: 'hello', protocol: 1, app: '0.0.0-test', device: 'Scripted phone' });
  assert.equal((await again.next('welcome')).pcId, pcId);
  assert.equal((await again.next('state')).type, 'state');
  again.close();
  say('after a restart the paired phone linked again through the room server');

  const lan = new ScriptedPhone({ socketUrl: `ws://127.0.0.1:${standin.lanPort}/remote`, pcId, phone: paired.phoneId, key: paired.secret, lan: true });
  phones.push(lan);
  await lan.connect();
  assert.match(lan.welcome.settings.session, /^[0-9a-f]{32}$/);
  assert.deepEqual(await lan.link(), { linked: true });
  lan.send({ type: 'hello', protocol: 1, app: '0.0.0-test', device: 'Scripted phone' });
  await lan.next('welcome');
  const lanState = await lan.next('state');
  assert.equal(lanState.type, 'state');
  lan.close();
  say(`and through the home-network socket (session ${lan.welcome.settings.session.slice(0, 8)}…, signed phone-lan/pc-lan)`);

  await stopStandin(standin);
  const log = readFileSync(logPath, 'utf8');
  assert.match(log, /pc: got command .*action=toggle .*pc-commands=toggle\b/);
  assert.match(log, /pc: got command .*action=next .*pc-commands=toggle,volume,next\b/);
  const summary = log.match(/media: media summary .*/)?.[0];
  assert.ok(summary, 'the media summary is logged');
  const maxBuffered = Number(summary.match(/maxBuffered=(\d+)/)[1]);
  assert.ok(maxBuffered <= 65536 + 64 * 1024, `the PC never buffered much more than its high-water mark, 64 KiB in this test (${maxBuffered})`);
  assert.ok(Number(summary.match(/waits=(\d+)/)[1]) > 0, 'the PC waited for bufferedAmountLow');
  say(`PC side: ${summary.replace(/^.*media summary /, '')}`);
  say(`log file ${logPath}: ${log.trim().split('\n').length} lines`);
});
