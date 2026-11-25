// A scripted phone for the self-test: the phone's side of PHONE-REMOTE.md with node-datachannel (libdatachannel, as
// the app uses): the room server (or the PC's home-network socket), signed signals, the offer with `remote-v1` and
// `media-v1`, and a media reader that assembles the PC's frames.
import nodeDataChannel from 'node-datachannel';
import WebSocket from 'ws';
import { randomHex, signedSignal, parseSignal, verify } from '../lib/signing.js';

const { PeerConnection } = nodeDataChannel;

/** Messages arriving on something, with waiters for the next one that matches. */
class Inbox {
  constructor() {
    this.messages = [];
    this.waiters = [];
  }
  push(message) {
    const waiter = this.waiters.find((w) => w.match(message));
    if (waiter) {
      this.waiters.splice(this.waiters.indexOf(waiter), 1);
      clearTimeout(waiter.timer);
      waiter.resolve(message);
    } else {
      this.messages.push(message);
    }
  }
  next(match, timeoutMs = 10000, what = 'a message') {
    const index = this.messages.findIndex(match);
    if (index >= 0) return Promise.resolve(this.messages.splice(index, 1)[0]);
    return new Promise((resolve, reject) => {
      const waiter = { match, resolve };
      waiter.timer = setTimeout(() => {
        this.waiters.splice(this.waiters.indexOf(waiter), 1);
        reject(new Error(`Timed out waiting for ${what}`));
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }
}

export class ScriptedPhone {
  /**
   * @param {object} options
   * @param {string} options.socketUrl ws://…/remote (the room server's, or the PC's home-network socket)
   * @param {string} options.pcId
   * @param {string} options.phone `pair` or the phone id
   * @param {string} options.key the pairing code or the phone secret
   * @param {boolean} [options.lan] signing as `phone-lan` / checking `pc-lan`, with the session the socket hands out
   */
  constructor({ socketUrl, pcId, phone, key, lan = false }) {
    Object.assign(this, { socketUrl, pcId, phone, key, lan });
    this.signals = new Inbox();
    this.socketMessages = new Inbox();
    this.remoteMessages = new Inbox();
    this.reads = new Map();
    this.nextRead = 0;
    this.peer = null;
  }

  /** Opens the signaling socket: remote-phone → remote-welcome (+ remote-online). */
  async connect() {
    this.ws = new WebSocket(this.socketUrl, { perMessageDeflate: false });
    await new Promise((resolve, reject) => {
      this.ws.once('open', resolve);
      this.ws.once('error', reject);
    });
    this.ws.on('message', (data) => {
      const message = JSON.parse(data.toString('utf8'));
      if (message.type === 'signal') this.onSignal(message);
      else this.socketMessages.push(message);
    });
    this.ws.send(JSON.stringify({ type: 'remote-phone', target: this.pcId, number: 1 }));
    const welcome = await this.socketMessages.next((m) => m.type === 'remote-welcome', 5000, 'remote-welcome');
    this.welcome = { ...welcome, settings: JSON.parse(welcome.data) };
    this.presence = await this.socketMessages.next((m) => m.type === 'remote-online' || m.type === 'remote-offline', 5000, 'remote-online');
    return this.welcome;
  }

  sendSignal(kind, payload) {
    const text = signedSignal(this.key, this.lan ? 'phone-lan' : 'phone', this.phone, this.session, kind, payload);
    this.ws.send(JSON.stringify({ type: 'signal', data: text }));
  }

  onSignal(message) {
    const signal = parseSignal(message.data);
    if (!signal || signal.session !== this.session) return;
    if (signal.kind === 'rejected') {
      this.signals.push({ rejected: signal.payload, sender: message.sender });
      return;
    }
    if (!verify(this.key, this.lan ? 'pc-lan' : 'pc', signal.phone, signal.session, signal.kind, signal.payload, signal.auth)) {
      this.signals.push({ badSignature: true });
      return;
    }
    const payload = JSON.parse(signal.payload);
    if (signal.kind === 'sdp' && payload.type === 'answer') {
      this.peer.setRemoteDescription(payload.sdp, 'answer');
      this.signals.push({ answered: true, sender: message.sender });
    } else if (signal.kind === 'ice') {
      try {
        this.peer.addRemoteCandidate(payload.candidate, payload.mid ?? '0');
      } catch {}
    }
  }

  /**
   * Makes the offer and waits for both channels to open. Resolves to { rejected } when the PC turns the offer away
   * with a hint.
   */
  async link(timeoutMs = 15000) {
    this.session = this.lan ? this.welcome.settings.session : randomHex(16);
    const peer = new PeerConnection('phone', { iceServers: [] });
    this.peer = peer;
    peer.onLocalDescription((sdp, type) => this.sendSignal('sdp', JSON.stringify({ type: String(type).toLowerCase(), sdp })));
    peer.onLocalCandidate((candidate, mid) => this.sendSignal('ice', JSON.stringify({ candidate: candidate.replace(/^a=/, ''), mid: mid || '0' })));
    const opened = (channel) => new Promise((resolve) => channel.onOpen(resolve));
    this.remote = peer.createDataChannel('remote-v1');
    this.media = peer.createDataChannel('media-v1');
    this.remote.onMessage((data) => typeof data === 'string' && this.remoteMessages.push(JSON.parse(data)));
    this.media.onMessage((data) => this.onMedia(data));
    const open = Promise.all([opened(this.remote), opened(this.media)]).then(() => ({ linked: true }));
    // A rejection hint arrives as a signal; watch for it without a timer of its own.
    const rejected = new Promise((resolve) => {
      const waiter = { match: (s) => s.rejected, resolve: (s) => resolve({ rejected: s.rejected }) };
      this.signals.waiters.push(waiter);
      this.stopWatchingRejection = () => this.signals.waiters.splice(this.signals.waiters.indexOf(waiter), 1);
    });
    let timer;
    const timeout = new Promise((_, reject) => (timer = setTimeout(() => reject(new Error('The link didn\'t come up in time')), timeoutMs)));
    try {
      return await Promise.race([open, rejected, timeout]);
    } finally {
      clearTimeout(timer);
      this.stopWatchingRejection();
    }
  }

  send(message) {
    this.remote.sendMessage(JSON.stringify(message));
  }

  next(match, timeoutMs = 10000, what) {
    return this.remoteMessages.next(typeof match === 'string' ? (m) => m.type === match : match, timeoutMs, what ?? (typeof match === 'string' ? match : 'a message'));
  }

  /** Sends a request and waits for its answer (or an error for it). */
  async ask(message, timeoutMs = 10000) {
    this.requests = (this.requests ?? 0) + 1;
    const request = this.requests;
    this.send({ ...message, request });
    return this.next((m) => m.request === request, timeoutMs, `the answer to ${message.type}`);
  }

  // media-v1 -------------------------------------------------------------------------------------------------------

  /** Reads part of a resource: resolves to { bytes, resourceLength }, or rejects with the read-error. */
  read(resource, offset, count) {
    const id = ++this.nextRead;
    const read = { id, received: 0, bytes: null, frames: 0 };
    read.promise = new Promise((resolve, reject) => {
      read.resolve = resolve;
      read.reject = reject;
    });
    this.reads.set(id, read);
    this.media.sendMessage(JSON.stringify({ type: 'read', id, resource, offset, count }));
    return read;
  }

  cancel(read) {
    this.media.sendMessage(JSON.stringify({ type: 'cancel', id: read.id }));
    read.cancelled = true;
  }

  onMedia(data) {
    if (typeof data === 'string') {
      const message = JSON.parse(data);
      const read = this.reads.get(message.id);
      if (message.type === 'read-error' && read) {
        this.reads.delete(message.id);
        const error = new Error(message.message);
        error.code = message.code;
        read.reject(error);
      }
      return;
    }
    const frame = Buffer.from(data);
    const id = frame.readUInt32LE(0);
    const offset = frame.readInt32LE(4);
    const total = frame.readInt32LE(8);
    const resourceLength = Number(frame.readBigInt64LE(16));
    const read = this.reads.get(id);
    this.framesSeen = (this.framesSeen ?? 0) + 1;
    this.largestFrame = Math.max(this.largestFrame ?? 0, frame.length - 24);
    if (!read) return;
    read.frames++;
    read.bytes ??= Buffer.alloc(total);
    frame.copy(read.bytes, offset, 24);
    read.received += frame.length - 24;
    if (read.received >= total) {
      this.reads.delete(id);
      read.resolve({ bytes: read.bytes, resourceLength, frames: read.frames });
    }
  }

  close() {
    try {
      this.remote?.close();
      this.media?.close();
      this.peer?.close();
    } catch {}
    this.ws?.close();
  }
}
