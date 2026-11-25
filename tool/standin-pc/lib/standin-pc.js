// A stand-in for the BlackPearl desktop app's phone remote (PHONE-REMOTE.md): it connects to a room server as a PC,
// pairs phones with one-time codes, answers their signed WebRTC offers with libdatachannel (node-datachannel, the
// library the phone app uses), and speaks `remote-v1` and `media-v1` over the link, changing a made-up player state
// and serving a made-up library whose videos are all one real file.
import nodeDataChannel from 'node-datachannel';
import WebSocket from 'ws';
import { isLanSession, parseSignal, pcIdOf, randomHex, signedSignal, verify } from './signing.js';
import { short } from './log.js';
import { LibraryError } from './library.js';
import { MediaServer, ReadError } from './media.js';
import { makePicture } from './jpeg.js';

const { PeerConnection } = nodeDataChannel;

export const allFeatures = ['library', 'watch', 'queues', 'unwatched', 'mark-watched', 'shuffle', 'tracks'];
export const defaultFeatures = ['library', 'watch', 'mark-watched', 'queues', 'unwatched'];
const pairingLifetimeMs = 10 * 60 * 1000;
const libraryWaitMs = 15000;
const roomOnly = new Set(['volume', 'mute', 'fullscreen']);

export class StandinPc {
  /**
   * @param {object} options
   * @param {import('./store.js').Store} options.store
   * @param {import('./library.js').Library} options.library
   * @param {Awaited<ReturnType<import('./video.js').openVideo>>} options.video
   * @param {import('./log.js').Log} options.log
   * @param {string} options.roomUrl the room server's base URL as this PC reaches it (http(s)://…)
   * @param {string} options.publicUrl the room server's base URL as phones reach it, for the pairing link
   * @param {string} [options.name]
   * @param {string[]} [options.features]
   * @param {string|null} [options.extraCandidateHost] also offer each host candidate's port at this address (10.0.2.2:
   *   the emulator's way to the host's 127.0.0.1)
   * @param {number} [options.loadingMs] the library answers only after this long, as BlackPearl's window does at start
   * @param {boolean} [options.logReads]
   * @param {number} [options.highWater] media-v1 send-buffer high-water mark in bytes
   */
  constructor({ store, library, video, log, roomUrl, publicUrl, name, features = defaultFeatures, extraCandidateHost = '10.0.2.2', loadingMs = 0, logReads = false, highWater = 1024 * 1024 }) {
    this.store = store;
    this.library = library;
    this.video = video;
    this.log = log;
    this.roomUrl = roomUrl;
    this.publicUrl = publicUrl;
    this.name = name ?? store.data.name ?? 'Stand-in PC';
    this.features = features;
    this.extraCandidateHost = extraCandidateHost;
    this.libraryReadyAt = Date.now() + loadingMs;
    this.logReads = logReads;
    this.highWater = highWater;
    this.hostKey = store.hostKey;
    this.pcId = pcIdOf(this.hostKey);
    this.iceServers = [];
    this.forceRelay = false;
    this.socket = null;
    this.stopped = false;
    this.lan = null; // set by LanListener: { port, addresses }
    /** Session key (`<phone label>`) → the live session of that phone or pairing code. */
    this.sessions = new Map();
    /** Sessions seen per phone label, to refuse a repeated offer. */
    this.seenSessions = new Set();
    /** Sessions a `rejected` hint went to already (once per session). */
    this.rejected = new Set();
    this.commands = [];
    this.code = null;
    this.codeUsed = false;
    this.codeExpires = 0;
    this.codeTimer = null;
    this.onPairingLink = null;
    this.pictures = new Map();
    this.state = this.initialState();
    this.stateTimer = setInterval(() => this.broadcastState(), 5000);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Pairing codes and the pairing link

  newCode() {
    this.code = randomHex(16);
    this.codeUsed = false;
    this.codeExpires = Date.now() + pairingLifetimeMs;
    clearTimeout(this.codeTimer);
    this.codeTimer = setTimeout(() => {
      this.log.write('pc', 'pairing code expired, here is a new one');
      this.newCode();
    }, pairingLifetimeMs);
    this.codeTimer.unref?.();
    this.onPairingLink?.(this.pairingLink());
    return this.code;
  }

  liveCode() {
    return this.code && !this.codeUsed && Date.now() < this.codeExpires ? this.code : null;
  }

  pairingLink() {
    return `blackpearl://pair?v=1&pc=${this.pcId}&code=${this.code}&server=${encodeURIComponent(this.publicUrl)}&name=${encodeURIComponent(this.name)}`;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // The room server link

  start() {
    this.newCode();
    this.connectRoom(0);
  }

  async stop() {
    this.stopped = true;
    clearInterval(this.stateTimer);
    clearTimeout(this.codeTimer);
    for (const session of [...this.sessions.values()]) this.closeSession(session, 'stopped');
    this.socket?.close();
    this.store.saveNow();
  }

  connectRoom(attempt) {
    if (this.stopped) return;
    const url = new URL(this.roomUrl);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    url.pathname = `${url.pathname.replace(/\/$/, '')}/remote`;
    const socket = new WebSocket(url, { perMessageDeflate: false });
    this.socket = socket;
    let ready = false;
    let replaced = false;
    socket.on('open', () => socket.send(JSON.stringify({ type: 'remote-pc', data: this.hostKey, number: 1 })));
    socket.on('message', (data) => {
      let message;
      try {
        message = JSON.parse(data.toString('utf8'));
      } catch {
        return;
      }
      switch (message.type) {
        case 'remote-welcome': {
          ready = true;
          try {
            const settings = JSON.parse(message.data ?? '{}');
            this.iceServers = Array.isArray(settings.iceServers) ? settings.iceServers.filter((s) => typeof s === 'string') : [];
            this.forceRelay = settings.forceRelay === true;
          } catch {
            this.iceServers = [];
          }
          const matches = typeof message.target === 'string' && message.target.toUpperCase() === this.pcId;
          this.log.write('pc', 'room server ready', { pc: this.pcId, iceServers: this.iceServers.length, forceRelay: this.forceRelay, idMatches: matches, attempts: attempt });
          break;
        }
        case 'signal':
          if (typeof message.sender === 'string' && typeof message.data === 'string') {
            this.handleSignal(message.data, {
              via: 'server',
              sender: message.sender,
              reply: (text) => this.socket === socket && socket.readyState === WebSocket.OPEN && socket.send(JSON.stringify({ type: 'signal', target: message.sender, data: text })),
            });
          }
          break;
        case 'peer-left':
          this.log.write('pc', 'phone left the room server', { conn: short(message.sender) });
          break;
        case 'closed':
          replaced = true;
          this.log.write('pc', 'room server: replaced', { text: message.text });
          break;
        case 'error':
          this.log.write('pc', 'room server: refused', { text: message.text });
          break;
        case 'pong':
          break;
        default:
          break;
      }
    });
    const ping = setInterval(() => socket.readyState === WebSocket.OPEN && socket.send(JSON.stringify({ type: 'ping', number: 1 })), 25000);
    ping.unref?.();
    socket.on('error', (error) => this.log.write('pc', 'room server unreachable', { error: error.message }));
    socket.on('close', () => {
      clearInterval(ping);
      if (this.stopped || this.socket !== socket) return;
      if (replaced) {
        this.log.write('pc', 'room server link stopped: another PC with this host key connected');
        return;
      }
      const delay = Math.min(30000, 1000 * 2 ** Math.min(attempt, 5));
      if (ready) this.log.write('pc', 'room server lost', { retryInMs: delay });
      setTimeout(() => this.connectRoom(ready ? 0 : attempt + 1), ready ? 1000 : delay).unref?.();
    });
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Signed signals

  /** The key a new offer from `phone` must be signed with, or the refusal hint. */
  keyFor(phone) {
    if (phone === 'pair') {
      const code = this.liveCode();
      return code ? { key: code, label: `pair:${code}` } : { refusal: 'pairing-expired' };
    }
    const known = this.store.data.phones[phone.toLowerCase()];
    return known ? { key: known.secret, label: phone.toLowerCase() } : { refusal: 'unknown-phone' };
  }

  /**
   * One signal from a phone. `path` is { via: 'server'|'lan', reply(text), sender?, session? (the handed-out one on
   * the home network) }. Returns true when the signal verified (a home-network connection has then proved itself).
   */
  handleSignal(data, path) {
    const signal = parseSignal(data);
    if (!signal) return false;
    const lan = path.via === 'lan';
    const direction = lan ? 'phone-lan' : 'phone';
    const refused = (reason) => {
      const key = `${signal.session}/${reason}`;
      if (!this.rejected.has(key)) this.log.write('pc', 'signal refused', { reason, phone: short(signal.phone), session: short(signal.session), via: path.via });
      this.rejected.add(key);
      return false;
    };
    if (lan && signal.session.toLowerCase() !== path.session) return refused('wrong-session');
    if (!lan && isLanSession(this.hostKey, signal.session)) return refused('lan-session');
    const isPair = signal.phone === 'pair';
    const phoneKey = isPair ? 'pair' : signal.phone.toLowerCase();

    if (signal.kind === 'ice') {
      const session = [...this.sessions.values()].find((s) => s.id === signal.session && s.phoneKey === phoneKey);
      if (!session || session.via !== path.via) return false;
      if (!verify(session.key, direction, signal.phone, signal.session, signal.kind, signal.payload, signal.auth)) return refused('bad-signature');
      if (!lan) session.reply = path.reply;
      try {
        const payload = JSON.parse(signal.payload);
        if (typeof payload.candidate === 'string' && payload.candidate) session.peer.addRemoteCandidate(payload.candidate, typeof payload.mid === 'string' && payload.mid ? payload.mid : '0');
      } catch (error) {
        this.log.write('pc', 'unusable candidate', { session: short(session.id), error: error.message });
      }
      return true;
    }
    if (signal.kind !== 'sdp') return false;

    const { key, label, refusal } = this.keyFor(signal.phone);
    if (refusal || (isPair && !verify(key, direction, signal.phone, signal.session, signal.kind, signal.payload, signal.auth))) {
      // A pair offer signed with a code that isn't the live one gets pairing-expired too. The hint goes through the room
      // server only, once per session.
      const reason = refusal ?? 'pairing-expired';
      if (!lan && !this.rejected.has(`${signal.session}/hint`)) {
        this.rejected.add(`${signal.session}/hint`);
        path.reply(JSON.stringify({ phone: signal.phone, session: signal.session, kind: 'rejected', payload: reason, auth: '' }));
      }
      return refused(reason);
    }
    if (!verify(key, direction, signal.phone, signal.session, signal.kind, signal.payload, signal.auth)) return refused('bad-signature');
    let offer;
    try {
      offer = JSON.parse(signal.payload);
    } catch {
      return refused('unreadable-offer');
    }
    if (offer?.type !== 'offer' || typeof offer.sdp !== 'string') return true;
    const seenKey = `${label}/${signal.session.toLowerCase()}`;
    if (this.seenSessions.has(seenKey)) return refused('repeated-offer');
    this.seenSessions.add(seenKey);
    this.openSession({ id: signal.session, phone: signal.phone, phoneKey, label, key, via: path.via, reply: path.reply, sdp: offer.sdp });
    return true;
  }

  sendSignal(session, kind, payload) {
    const direction = session.via === 'lan' ? 'pc-lan' : 'pc';
    session.reply(signedSignal(session.key, direction, session.phone, session.id, kind, payload));
  }

  openSession({ id, phone, phoneKey, label, key, via, reply, sdp }) {
    const earlier = this.sessions.get(label);
    if (earlier) this.closeSession(earlier, 'replaced');
    const known = phoneKey === 'pair' ? null : this.store.data.phones[phoneKey];
    const session = {
      id,
      phone,
      phoneKey,
      label,
      key,
      via,
      reply,
      pairing: phoneKey === 'pair',
      phoneName: known?.name ?? null,
      pairedPhoneId: phoneKey === 'pair' ? null : phoneKey,
      opened: Date.now(),
      peer: null,
      remote: null,
      media: null,
      mediaServer: null,
      greeted: false,
      stream: null,
      closed: false,
      extraPorts: new Set(),
    };
    this.sessions.set(label, session);
    const relay = via === 'server' && this.forceRelay;
    this.log.write('pc', 'session opened', { session: short(id), phone: short(phone), pairing: session.pairing, replaced: !!earlier, via, name: session.phoneName ?? undefined });
    const peer = new PeerConnection(`pc-${short(id)}`, {
      iceServers: via === 'lan' ? [] : this.iceServers,
      iceTransportPolicy: relay ? 'relay' : 'all',
      maxMessageSize: 262144,
    });
    session.peer = peer;
    let answered = false;
    peer.onLocalDescription((description, type) => {
      if (answered || session.closed) return;
      answered = true;
      this.sendSignal(session, 'sdp', JSON.stringify({ type: String(type).toLowerCase(), sdp: description }));
    });
    peer.onLocalCandidate((candidate, mid) => {
      if (session.closed) return;
      const line = candidate.startsWith('a=') ? candidate.slice(2) : candidate;
      this.sendSignal(session, 'ice', JSON.stringify({ candidate: line, mid: mid || '0' }));
      this.extraCandidate(session, line, mid || '0');
    });
    peer.onStateChange((state) => {
      this.log.write('pc', 'session state', { session: short(id), state, path: state === 'connected' ? this.pathOf(peer) : undefined });
      if (state === 'failed' || state === 'closed') this.closeSession(session, state);
    });
    peer.onDataChannel((channel) => this.onChannel(session, channel));
    try {
      peer.setRemoteDescription(sdp, 'offer');
    } catch (error) {
      this.log.write('pc', 'offer unusable', { session: short(id), error: String(error?.message ?? error) });
      this.closeSession(session, 'unreadable-offer');
    }
  }

  /** On the emulator the host's 127.0.0.1 is 10.0.2.2: offer each host candidate's port there as well. */
  extraCandidate(session, line, mid) {
    if (!this.extraCandidateHost || session.via === 'lan') return;
    const parts = line.split(' ');
    if (parts.length < 8 || parts[2].toUpperCase() !== 'UDP' || parts[7] !== 'host') return;
    const port = parts[5];
    if (session.extraPorts.has(port)) return;
    session.extraPorts.add(port);
    const candidate = `candidate:${9000 + session.extraPorts.size} 1 UDP ${2113929215 - session.extraPorts.size} ${this.extraCandidateHost} ${port} typ host`;
    this.sendSignal(session, 'ice', JSON.stringify({ candidate, mid }));
  }

  pathOf(peer) {
    try {
      const pair = peer.getSelectedCandidatePair();
      return pair ? `${pair.local.type}:${pair.local.address}:${pair.local.port}->${pair.remote.type}:${pair.remote.address}:${pair.remote.port}` : undefined;
    } catch {
      return undefined;
    }
  }

  closeSession(session, reason) {
    if (session.closed) return;
    session.closed = true;
    if (this.sessions.get(session.label) === session) this.sessions.delete(session.label);
    session.mediaServer?.close();
    for (const channel of [session.remote, session.media]) {
      try {
        channel?.close();
      } catch {}
    }
    try {
      session.peer?.close();
    } catch {}
    this.log.write('pc', 'session closed', { session: short(session.id), reason, ageMs: Date.now() - session.opened, via: session.via });
  }

  onChannel(session, channel) {
    const label = channel.getLabel();
    this.log.write('pc', 'channel opened', { session: short(session.id), label });
    if (label === 'remote-v1') {
      session.remote = channel;
      channel.onMessage((data) => {
        if (typeof data === 'string') this.onRemoteMessage(session, data);
      });
      channel.onClosed(() => this.closeSession(session, 'channel-closed'));
    } else if (label === 'media-v1') {
      session.media = channel;
      session.mediaServer = new MediaServer({
        channel,
        resolve: (resource) => this.resolveResource(session, resource),
        log: (event, fields) => this.log.write('media', event, { session: short(session.id), ...fields }),
        logReads: this.logReads,
        highWater: this.highWater,
      });
      channel.onMessage((data) => session.mediaServer.onMessage(data));
      channel.onClosed(() => session.mediaServer.close());
    } else {
      channel.close();
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // remote-v1

  send(session, message) {
    if (session.closed || !session.remote) return;
    try {
      if (session.remote.isOpen()) session.remote.sendMessage(JSON.stringify(message));
    } catch {}
  }

  error(session, code, message, request) {
    this.send(session, { type: 'error', code, message, ...(request === undefined ? {} : { request }) });
    this.log.write('pc', 'sent error', { session: short(session.id), code, request });
  }

  onRemoteMessage(session, text) {
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      this.log.write('pc', 'got unreadable message', { session: short(session.id) });
      return;
    }
    if (message === null || typeof message !== 'object') return;
    const fields = { session: short(session.id), phone: short(session.pairedPhoneId ?? 'pair') };
    for (const [key, value] of Object.entries(message)) {
      if (key !== 'type' && (value === null || typeof value !== 'object')) fields[key] = value;
    }
    if (message.type === 'command') {
      this.commands.push(message.action);
      fields['pc-commands'] = this.commands.join(',');
    }
    this.log.write('pc', `got ${message.type}`, fields);
    switch (message.type) {
      case 'hello':
        return this.onHello(session, message);
      case 'pair':
        return this.onPair(session, message);
      case 'command':
        return session.greeted && this.onCommand(session, message);
      case 'browse':
      case 'queues':
      case 'watch':
      case 'play':
      case 'progress':
      case 'mark-watched':
        return session.greeted && (!session.pairing || session.pairedPhoneId) ? this.onLibrary(session, message) : undefined;
      case 'stream-stop':
        session.stream = null;
        return;
      default:
        return; // Unknown types are ignored.
    }
  }

  onHello(session, message) {
    if (message.protocol !== 1) {
      this.error(session, 'protocol', message.protocol > 1 ? 'This PC speaks an older phone remote. Update BlackPearl on the PC.' : 'Update BlackPearl Mobile to connect to this PC.');
      setTimeout(() => this.closeSession(session, 'protocol'), 500).unref?.();
      return;
    }
    session.greeted = true;
    session.device = message.device;
    const welcome = { type: 'welcome', protocol: 1, app: 'standin-pc 1.0.0', pc: this.name, pcId: this.pcId, canStart: true, features: this.features };
    if (this.lan) welcome.lan = this.lan;
    this.send(session, welcome);
    if (!session.pairing) this.sendState(session);
  }

  onPair(session, message) {
    if (!session.greeted) return;
    if (!session.pairing || session.pairedPhoneId || session.key !== this.liveCode()) {
      this.error(session, 'pairing', session.pairing && !session.pairedPhoneId ? 'That code has expired. Show a new one on the PC.' : 'This phone is already paired.');
      return;
    }
    this.codeUsed = true;
    const phoneId = randomHex(16);
    const secret = randomHex(32);
    const name = typeof message.name === 'string' && message.name ? message.name.slice(0, 100) : 'Phone';
    this.store.data.phones[phoneId] = { secret, name, pairedAt: new Date().toISOString() };
    this.store.saveNow();
    session.pairedPhoneId = phoneId;
    session.phoneName = name;
    this.send(session, { type: 'paired', phoneId, secret, pc: this.name, pcId: this.pcId });
    this.log.write('pc', 'paired', { phone: short(phoneId), name });
    this.sendState(session);
    this.newCode();
  }

  /** Removes a paired phone: its secret is deleted and its live session closed. */
  forget(prefix) {
    const id = Object.keys(this.store.data.phones).find((phone) => phone.startsWith(prefix.toLowerCase()));
    if (!id) return false;
    delete this.store.data.phones[id];
    this.store.saveNow();
    const session = this.sessions.get(id);
    if (session) this.closeSession(session, 'removed');
    for (const live of [...this.sessions.values()]) if (live.pairedPhoneId === id) this.closeSession(live, 'removed');
    return true;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // The made-up player

  initialState() {
    const state = {
      type: 'state',
      media: false,
      volume: 64,
      muted: false,
      loop: 'off',
      shuffle: false,
      fullscreen: false,
      canControl: true,
      room: null,
      audioTrack: 1,
      subtitleTrack: 3,
    };
    this.playing = null; // { id, queue }
    this.since = Date.now();
    Object.assign(state, { playing: false, positionMs: null, durationMs: null });
    const first = this.library.playable('show-night-signal-s1e3');
    if (first) this.load(state, first, null, 61000, true);
    return state;
  }

  load(state, item, queue, positionMs, playing) {
    const [title, detail] = this.library.describe(item);
    this.playing = { id: item.id, queue };
    Object.assign(state, { media: true, title, detail, playing, positionMs, durationMs: this.library.durationMs, mediaId: item.id });
    this.since = Date.now();
    this.updateSteps(state);
  }

  updateSteps(state) {
    const item = this.playing ? this.library.playable(this.playing.id) : null;
    if (!item) {
      Object.assign(state, { hasPrevious: false, hasNext: false, queue: null });
      return;
    }
    const context = this.library.context(item, this.playing.queue?.id, this.playing.queue?.index);
    this.playing.queue = context.queue;
    Object.assign(state, { hasPrevious: true, hasNext: !!context.next || state.loop === 'all', queue: context.queue });
  }

  /** The state with the position advanced to now, as the phone would show it. */
  currentState() {
    const state = this.state;
    if (state.media && state.playing) {
      const now = Date.now();
      state.positionMs = Math.min(state.durationMs, state.positionMs + (now - this.since));
      this.since = now;
    }
    const out = { ...state };
    if (!state.media) {
      for (const key of ['title', 'detail', 'playing', 'positionMs', 'durationMs', 'hasPrevious', 'hasNext', 'mediaId']) out[key] = key === 'mediaId' ? null : key.startsWith('has') ? false : null;
    }
    if (!this.features.includes('shuffle')) delete out.shuffle;
    if (this.features.includes('tracks')) {
      Object.assign(out, {
        audioTracks: state.media ? [{ id: 1, name: 'Japanese', detail: 'Stereo' }, { id: 2, name: 'English', detail: '5.1' }] : [],
        subtitleTracks: state.media ? [{ id: -1, name: 'Off', detail: null }, { id: 3, name: 'English', detail: 'Full' }, { id: 4, name: 'English', detail: 'Signs' }] : [],
        canChangeTracks: state.media && (state.canControl || state.room === null),
      });
      if (!state.media) Object.assign(out, { audioTrack: null, subtitleTrack: null });
    } else {
      delete out.audioTrack;
      delete out.subtitleTrack;
    }
    return out;
  }

  sendState(session) {
    this.send(session, this.currentState());
  }

  broadcastState() {
    const state = this.currentState();
    for (const session of this.sessions.values()) {
      if (session.greeted && (!session.pairing || session.pairedPhoneId)) this.send(session, state);
    }
  }

  onCommand(session, message) {
    if (session.pairing && !session.pairedPhoneId) return;
    const { action, value } = message;
    const state = this.state;
    this.currentState(); // bring the position up to now
    const known = ['toggle', 'play', 'pause', 'seek-by', 'seek-to', 'previous', 'next', 'stop', 'volume', 'mute', 'loop', 'fullscreen'];
    if (this.features.includes('shuffle')) known.push('shuffle');
    if (this.features.includes('tracks')) known.push('audio-track', 'subtitle-track');
    if (!known.includes(action)) return; // Unknown actions are ignored.
    const tracks = action === 'audio-track' || action === 'subtitle-track';
    if (tracks) {
      if (!state.media || (!state.canControl && state.room)) {
        this.error(session, 'not-allowed', state.media ? 'Only the person playing the video can change its tracks in this room.' : 'Nothing is playing on the PC.');
        return this.broadcastState();
      }
    } else if (!state.canControl && !roomOnly.has(action)) {
      return this.error(session, 'not-allowed', 'In this room, only the person playing the video can control it.');
    }
    const needsMedia = !['volume', 'mute', 'loop', 'shuffle', 'fullscreen'].includes(action);
    if (needsMedia && !state.media && !tracks) return this.error(session, 'nothing-playing', 'Nothing is playing on the PC.');
    const number = typeof value === 'number' && Number.isFinite(value) ? Math.round(value) : null;
    const item = this.playing ? this.library.playable(this.playing.id) : null;
    switch (action) {
      case 'toggle':
        state.playing = !state.playing;
        break;
      case 'play':
        state.playing = true;
        break;
      case 'pause':
        state.playing = false;
        break;
      case 'seek-by':
        if (number !== null) state.positionMs = Math.max(0, Math.min(state.durationMs, state.positionMs + number));
        break;
      case 'seek-to':
        if (number !== null) state.positionMs = Math.max(0, Math.min(state.durationMs, number));
        break;
      case 'previous':
      case 'next': {
        const context = item ? this.library.context(item, this.playing.queue?.id, this.playing.queue?.index) : null;
        let step = action === 'next' ? context?.next : state.positionMs > 5000 ? null : context?.previous;
        if (action === 'next' && !step && state.loop === 'all') step = context?.first;
        if (step) this.load(state, step[0], step[1] == null ? null : { ...context.queue, index: step[1] }, 0, true);
        else if (action === 'previous') state.positionMs = 0;
        break;
      }
      case 'stop':
        state.media = false;
        state.playing = false;
        state.mediaId = null;
        this.playing = null;
        break;
      case 'volume':
        if (number !== null) state.volume = Math.max(0, Math.min(100, number));
        break;
      case 'mute':
        state.muted = !state.muted;
        break;
      case 'loop':
        state.loop = { off: 'all', all: 'one', one: 'off' }[state.loop] ?? 'off';
        break;
      case 'shuffle':
        state.shuffle = !state.shuffle;
        break;
      case 'fullscreen':
        if (!state.media) return this.error(session, 'not-shown', 'The PC isn\'t showing the player.');
        state.fullscreen = !state.fullscreen;
        break;
      case 'audio-track':
        if ([1, 2].includes(number)) state.audioTrack = number;
        break;
      case 'subtitle-track':
        if ([-1, 3, 4].includes(number)) state.subtitleTrack = number;
        break;
    }
    this.since = Date.now();
    if (state.media) this.updateSteps(state);
    this.broadcastState();
  }

  /** Simulates the PC joining (or leaving) a room where only whoever plays the video may control it. */
  toggleRoom() {
    this.currentState();
    if (this.state.room) {
      this.state.room = null;
      this.state.canControl = true;
    } else {
      this.state.room = { name: 'Movie club', people: 3 };
      this.state.canControl = false;
    }
    this.broadcastState();
    return this.state.room !== null;
  }

  stopPlayer() {
    this.state.media = false;
    this.state.playing = false;
    this.state.mediaId = null;
    this.playing = null;
    this.broadcastState();
  }

  // ---------------------------------------------------------------------------------------------------------------
  // The library

  async libraryReady() {
    const wait = this.libraryReadyAt - Date.now();
    if (wait <= 0) return true;
    await new Promise((resolve) => setTimeout(resolve, Math.min(wait, libraryWaitMs)));
    return Date.now() >= this.libraryReadyAt;
  }

  async onLibrary(session, message) {
    const request = message.request;
    if (!(await this.libraryReady())) {
      if (message.type !== 'progress') this.error(session, 'loading', 'BlackPearl is still reading its library. Try again in a moment.', request);
      return;
    }
    const library = this.library;
    try {
      switch (message.type) {
        case 'browse':
          try {
            const page = library.browse(message);
            this.send(session, page);
            this.log.write('pc', 'sent page', { session: short(session.id), request, location: page.location, total: page.total, entries: page.entries.length });
          } catch (error) {
            if (error instanceof LibraryError) throw new LibraryError('browse', error.message);
            throw error;
          }
          break;
        case 'queues':
          this.send(session, { type: 'queues', request, queues: library.queueList(this.state.media ? this.state.queue : null) });
          break;
        case 'watch': {
          const stream = library.watch(message);
          if (message.takeOver === true && this.state.media && this.state.mediaId === stream.id) {
            this.stopPlayer();
            this.log.write('pc', 'the video went on to the phone', { id: stream.id });
          }
          session.stream = { id: stream.id };
          this.send(session, stream);
          this.log.write('pc', 'sent stream', { session: short(session.id), request, id: stream.id, resource: stream.resource, length: stream.length, positionMs: stream.positionMs });
          break;
        }
        case 'progress':
          if (this.state.media && this.state.mediaId === message.id) return;
          library.progress(message);
          break;
        case 'play': {
          if (this.state.room) throw new LibraryError('in-room', 'The PC is in a room. Leave it there to play this.');
          const item = library.playable(message.id);
          if (!item) throw new LibraryError('gone', 'That video isn\'t in the library any more.');
          session.stream = null;
          const position = typeof message.positionMs === 'number' ? Math.max(0, Math.round(message.positionMs)) : 0;
          const queue = typeof message.queue === 'string' ? { id: message.queue, index: message.queueIndex } : null;
          this.load(this.state, item, queue, position, true);
          this.send(session, { type: 'done', request });
          this.broadcastState();
          break;
        }
        case 'mark-watched': {
          const count = library.markWatched(message);
          this.send(session, { type: 'done', request });
          this.log.write('pc', 'marked', { id: message.id, level: message.level, watched: message.watched, videos: count });
          break;
        }
      }
    } catch (error) {
      if (error instanceof LibraryError) this.error(session, error.code, error.message, request);
      else {
        this.log.write('pc', 'library request failed', { error: error.stack ?? String(error) });
        this.error(session, message.type === 'browse' ? 'browse' : 'gone', 'The PC couldn\'t do that.', request);
      }
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // media-v1 resources

  async resolveResource(session, resource) {
    const parts = resource.split('/');
    if (parts[0] === 'file' && parts.length === 2) {
      if (!session.stream) throw new ReadError('gone', 'The phone isn\'t watching anything from this PC.', 'no-video');
      if (session.stream.id !== parts[1]) throw new ReadError('gone', 'That isn\'t the video the phone is watching.', 'other-video');
      return { length: this.video.size, read: (offset, count) => this.video.read(offset, count) };
    }
    if (parts[0] === 'art' && parts.length === 3) {
      const width = Number(parts[2]);
      if (!Number.isInteger(width) || width < 64 || width > 1280) throw new ReadError('invalid', 'That picture size isn\'t one the PC makes.', 'malformed');
      const natural = this.library.pictures.get(parts[1]);
      if (!natural) throw new ReadError('gone', 'The PC has no such picture.', 'unknown-picture');
      const key = `${parts[1]}/${Math.min(width, natural.width)}`;
      let picture = this.pictures.get(key);
      if (!picture) {
        picture = makePicture(parts[1], width, natural.width, natural.height);
        if (this.pictures.size > 300) this.pictures.clear();
        this.pictures.set(key, picture);
      }
      return { length: picture.length, read: async (offset, count) => picture.subarray(offset, offset + count) };
    }
    if (parts[0] === 'stream') throw new ReadError('gone', 'This stand-in PC doesn\'t convert videos.', 'not-converted');
    throw new ReadError('invalid', 'The PC doesn\'t know that resource.', 'malformed');
  }
}
