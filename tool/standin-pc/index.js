#!/usr/bin/env node
// A room server and a stand-in BlackPearl PC, for testing BlackPearl Mobile end to end on an Android emulator without
// the desktop app. See README.md.
import { parseArgs } from 'node:util';
import { createInterface } from 'node:readline';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import nodeDataChannel from 'node-datachannel';
import { Log } from './lib/log.js';
import { RoomServer } from './lib/room-server.js';
import { Store } from './lib/store.js';
import { openConversion, openVideo } from './lib/video.js';
import { Library } from './lib/library.js';
import { StandinPc, allFeatures, defaultFeatures } from './lib/standin-pc.js';
import { LanListener } from './lib/lan.js';

const here = dirname(fileURLToPath(import.meta.url));

const usage = `Usage: node index.js --video <file> [options]

  --video <file>          the real video every playable library entry plays (read only)
  --conversion <folder>   answer a watch that asks for a conversion with this one: stream.ts (one piece) and
                          subtitles.json, a list of {language, title, codec, burn, file}; see README.md
  --port <n>              room server port (default 8790; 0 picks a free one)
  --bind <address>        where the room server and the home-network socket listen (default 127.0.0.1;
                          0.0.0.0 to let a real phone on the network in)
  --public-url <url>      the room server as the phone reaches it, put in the pairing link
                          (default http://10.0.2.2:<port>, the emulator's name for this computer)
  --connect <url>         don't start a room server; connect the stand-in PC to this one instead
  --name <text>           the PC's name (default "Stand-in PC")
  --state <file>          host key, paired phones and resume points (default .state/standin-pc.json here)
  --log <file>            also append every log line to this file
  --features <list>       comma-separated welcome features (default ${defaultFeatures.join(',')};
                          known: ${allFeatures.join(',')})
  --loading-ms <n>        answer library requests only after this long, as BlackPearl does while it reads its library
  --lan-port <n>          first port for the home-network socket (default 47830, tries up to +9); --no-lan to skip it
  --lan-address <list>    the addresses the welcome's "lan" gives phones (default 10.0.2.2)
  --extra-candidate <ip>  also offer the PC's ICE ports at this address (default 10.0.2.2; "none" to turn off)
  --log-reads             log every media-v1 read and cancel (default: a summary every 5 seconds)
  --high-water <bytes>    media-v1 frames wait while this much is buffered on the channel (default 1048576)
  --package <id>          the app the printed adb line opens the link in (default io.github.svovoniks.blackpearlmobile)
  --help

Type "help" while it runs for the commands it takes on stdin.`;

let options;
try {
  options = parseArgs({
    options: {
      video: { type: 'string' },
      conversion: { type: 'string' },
      port: { type: 'string', default: '8790' },
      bind: { type: 'string', default: '127.0.0.1' },
      'public-url': { type: 'string' },
      connect: { type: 'string' },
      name: { type: 'string' },
      state: { type: 'string', default: join(here, '.state', 'standin-pc.json') },
      log: { type: 'string' },
      features: { type: 'string' },
      'loading-ms': { type: 'string', default: '0' },
      'lan-port': { type: 'string', default: '47830' },
      'no-lan': { type: 'boolean', default: false },
      'lan-address': { type: 'string', default: '10.0.2.2' },
      'extra-candidate': { type: 'string', default: '10.0.2.2' },
      'log-reads': { type: 'boolean', default: false },
      'high-water': { type: 'string', default: String(1024 * 1024) },
      package: { type: 'string', default: 'io.github.svovoniks.blackpearlmobile' },
      help: { type: 'boolean', default: false },
    },
  }).values;
} catch (error) {
  console.error(`${error.message}\n\n${usage}`);
  process.exit(2);
}
if (options.help) {
  console.log(usage);
  process.exit(0);
}
if (!options.video) {
  console.error(`--video is required.\n\n${usage}`);
  process.exit(2);
}

const log = new Log({ path: options.log ? resolve(options.log) : null });
const features = options.features ? options.features.split(',').map((f) => f.trim()).filter(Boolean) : defaultFeatures;

let video;
try {
  video = await openVideo(resolve(options.video));
} catch (error) {
  console.error(`Can't open the video: ${error.message}`);
  process.exit(1);
}

let server = null;
let roomUrl = options.connect;
let publicUrl = options['public-url'] ?? options.connect;
if (!options.connect) {
  server = new RoomServer({ log });
  let port;
  try {
    port = await server.listen(Number(options.port), options.bind);
  } catch (error) {
    console.error(`The room server can't listen on ${options.bind}:${options.port}: ${error.message}`);
    process.exit(1);
  }
  roomUrl = `http://${options.bind === '0.0.0.0' ? '127.0.0.1' : options.bind}:${port}`;
  publicUrl ??= `http://10.0.2.2:${port}`;
  log.write('server', 'listening', { url: roomUrl, port, health: `${roomUrl}/health`, phonesUse: publicUrl });
}

const store = new Store(resolve(options.state));
if (options.name) store.data.name = options.name;
let conversion = null;
if (options.conversion) {
  try {
    conversion = await openConversion(resolve(options.conversion));
  } catch (error) {
    console.error(`Can't open the conversion: ${error.message}`);
    process.exit(1);
  }
}
const library = new Library({ video, store, conversion });
const pc = new StandinPc({
  store,
  library,
  video,
  log,
  roomUrl,
  publicUrl,
  name: options.name,
  features,
  extraCandidateHost: options['extra-candidate'] === 'none' ? null : options['extra-candidate'],
  loadingMs: Number(options['loading-ms']) || 0,
  logReads: options['log-reads'],
  highWater: Math.max(16 * 1024, Number(options['high-water']) || 1024 * 1024),
});
log.write('pc', 'video', { path: video.path, bytes: video.size, durationMs: video.durationMs ?? 'unknown', extension: video.extension });
log.write('pc', 'identity', { name: pc.name, pcId: pc.pcId, pairedPhones: Object.keys(store.data.phones).length, state: store.path, features: features.join(',') });

let lan = null;
if (!options['no-lan']) {
  const first = Number(options['lan-port']) || 47830;
  lan = new LanListener({ pc, log, bind: options.bind, addresses: options['lan-address'].split(',').map((a) => a.trim()).filter(Boolean), firstPort: first, lastPort: first + 9 });
  await lan.start();
}

// -p: with another build of the app installed under a different package id, Android would ask which app opens it.
const adbCommand = (link) => `adb shell "am start -a android.intent.action.VIEW -p ${options.package} -d '${link}'"`;
pc.onPairingLink = (link) => {
  log.write('pc', 'pairing link', { link });
  console.log(`\nPair a phone (one use, 10 minutes):\n  ${link}\nOn the emulator:\n  ${adbCommand(link)}\n`);
};
pc.start();

const help = `Commands:
  pair            a new pairing code and link
  link            show the current pairing link again
  phones          list paired phones
  forget <id>     remove a paired phone (its id or the start of it)
  room            join or leave a pretend room where the phone can't control playback
  stop            stop the PC's player (nothing playing)
  state           print the state the phones get
  server off|on   take the room server down (phones then try the home-network socket) or bring it back
  quit            stop everything`;

const input = createInterface({ input: process.stdin, terminal: false });
input.on('line', (line) => {
  const [command, argument] = line.trim().split(/\s+/);
  switch (command) {
    case '':
      return;
    case 'pair':
      pc.newCode();
      return;
    case 'link':
      console.log(`${pc.pairingLink()}\n${adbCommand(pc.pairingLink())}`);
      return;
    case 'phones':
      for (const [id, phone] of Object.entries(store.data.phones)) console.log(`${id}  ${phone.name}  paired ${phone.pairedAt}`);
      if (Object.keys(store.data.phones).length === 0) console.log('No paired phones.');
      return;
    case 'forget':
      console.log(argument && pc.forget(argument) ? 'Removed.' : 'No such phone.');
      return;
    case 'room':
      console.log(pc.toggleRoom() ? 'In a room: only volume, mute and fullscreen work from the phone.' : 'Left the room.');
      return;
    case 'stop':
      pc.stopPlayer();
      return;
    case 'state':
      console.log(JSON.stringify(pc.currentState(), null, 2));
      return;
    case 'server':
      if (!server) console.log('This run connects to another room server (--connect).');
      else if (argument === 'off' || argument === 'on') void server.setDown(argument === 'off');
      else console.log('server off, or server on');
      return;
    case 'quit':
    case 'exit':
      void shutdown();
      return;
    default:
      console.log(help);
  }
});

let stopping = false;
async function shutdown() {
  if (stopping) return;
  stopping = true;
  log.write('pc', 'stopping');
  input.close();
  await pc.stop();
  await lan?.close();
  await server?.close();
  await video.close();
  nodeDataChannel.cleanup();
  process.exit(0);
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
