// The room server's `/remote` endpoint (PHONE-REMOTE.md, "Room server: /remote"): it introduces phones to their PC and
// forwards signed signals both ways; commands and state never pass through it. Plus `/health`.
import { createServer } from 'node:http';
import { WebSocketServer } from 'ws';
import { isHex, pcIdOf, randomHex } from './signing.js';
import { short } from './log.js';

const maxMessage = 64 * 1024;
const maxPhonesPerPc = 8;

export class RoomServer {
  /**
   * @param {object} options
   * @param {import('./log.js').Log} options.log
   * @param {string[]} [options.iceServers] handed to both sides in `remote-welcome` (empty by default: host candidates only)
   * @param {boolean} [options.forceRelay]
   * @param {number} [options.maxAgeMs] how long a connection may last (6 hours, as the real server)
   */
  constructor({ log, iceServers = [], forceRelay = false, maxAgeMs = 6 * 60 * 60 * 1000 }) {
    this.log = log;
    this.iceServers = iceServers;
    this.forceRelay = forceRelay;
    this.maxAgeMs = maxAgeMs;
    /** PC id → its socket. */
    this.pcs = new Map();
    /** connection id → { socket, target (PC id) }. */
    this.phones = new Map();
    this.http = createServer((request, response) => this.onHttp(request, response));
    this.wss = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024, perMessageDeflate: false });
    this.http.on('upgrade', (request, socket, head) => {
      if (new URL(request.url, 'http://x').pathname !== '/remote') {
        socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
        return;
      }
      this.wss.handleUpgrade(request, socket, head, (ws) => this.accept(ws, request));
    });
  }

  listen(port, host) {
    return new Promise((resolve, reject) => {
      this.http.once('error', reject);
      this.http.listen(port, host, () => {
        this.http.off('error', reject);
        resolve(this.http.address().port);
      });
    });
  }

  close() {
    for (const ws of this.wss.clients) ws.terminate();
    return new Promise((resolve) => this.http.close(() => resolve()));
  }

  /** Takes the server down (every connection dropped) or brings it back on the same port, to try the home network. */
  async setDown(down) {
    if (down === !this.http.listening) return;
    if (down) {
      const { port, address } = this.http.address();
      this.downAt = { port, address };
      await this.close();
      this.log.write('server', 'down');
    } else {
      await this.listen(this.downAt.port, this.downAt.address);
      this.log.write('server', 'up again', { port: this.downAt.port });
    }
  }

  onHttp(request, response) {
    const path = new URL(request.url, 'http://x').pathname;
    if (path === '/health') {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ status: 'ok', remote: 1, pcs: this.pcs.size, phones: this.phones.size }));
      return;
    }
    response.writeHead(404, { 'content-type': 'text/plain' });
    response.end('Not found');
  }

  accept(ws, request) {
    const from = request.socket.remoteAddress;
    let role = null; // 'pc' or 'phone'
    let pcId = null;
    let connectionId = null;
    const send = (message) => {
      if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(message));
    };
    const fail = (text) => {
      this.log.write('server', 'refused', { role: role ?? 'unknown', reason: text });
      send({ type: 'error', text });
      ws.close(1008, 'error');
    };
    const ageLimit = setTimeout(() => {
      this.log.write('server', 'connection reached its age limit', { role, conn: short(connectionId ?? pcId) });
      ws.close(1000, 'age');
    }, this.maxAgeMs);
    ageLimit.unref?.();

    ws.on('message', (data, isBinary) => {
      if (isBinary) return fail('Binary messages are not supported.');
      if (data.length > maxMessage) return fail('Message too large.');
      let message;
      try {
        message = JSON.parse(data.toString('utf8'));
      } catch {
        return fail('Unreadable message.');
      }
      if (message === null || typeof message !== 'object') return fail('Unreadable message.');
      const { type } = message;
      if (type === 'ping') {
        send({ type: 'pong', number: message.number, data: String(Date.now()) });
        return;
      }
      if (role === null) {
        if (type !== 'remote-pc' && type !== 'remote-phone') return fail('Say remote-pc or remote-phone first.');
        if (message.number !== 1) {
          return fail(
            typeof message.number === 'number' && message.number > 1
              ? 'This room server speaks phone remote version 1. Update the room server.'
              : `This room server speaks phone remote version 1. Update the ${type === 'remote-pc' ? 'BlackPearl app on the PC' : 'phone app'}.`,
          );
        }
        if (type === 'remote-pc') {
          if (!isHex(message.data, 64)) return fail('That is not a host key.');
          role = 'pc';
          pcId = pcIdOf(message.data);
          const earlier = this.pcs.get(pcId);
          if (earlier && earlier !== ws) {
            this.log.write('server', 'pc replaced by a newer connection', { pc: short(pcId) });
            earlier.send(JSON.stringify({ type: 'closed', text: 'A newer connection for this PC replaced this one.' }));
            earlier.close(1000, 'replaced');
          }
          this.pcs.set(pcId, ws);
          send({ type: 'remote-welcome', target: pcId, data: JSON.stringify({ iceServers: this.iceServers, forceRelay: this.forceRelay }) });
          this.log.write('server', 'pc connected', { pc: pcId, from });
          for (const phone of this.phones.values()) {
            if (phone.target === pcId) phone.socket.send(JSON.stringify({ type: 'remote-online' }));
          }
        } else {
          if (!isHex(message.target, 32)) return fail('That is not a PC id.');
          const target = message.target.toUpperCase();
          const count = [...this.phones.values()].filter((phone) => phone.target === target).length;
          if (count >= maxPhonesPerPc) return fail('Too many phones are connecting to this PC.');
          role = 'phone';
          pcId = target;
          connectionId = randomHex(16);
          this.phones.set(connectionId, { socket: ws, target });
          send({ type: 'remote-welcome', target: connectionId, data: JSON.stringify({ iceServers: this.iceServers, forceRelay: this.forceRelay }) });
          const online = this.pcs.has(target);
          send({ type: online ? 'remote-online' : 'remote-offline' });
          this.log.write('server', 'phone connected', { conn: short(connectionId), pc: short(target), online, from });
        }
        return;
      }
      if (type !== 'signal') return; // Unknown types are ignored.
      if (typeof message.data !== 'string') return fail('A signal needs data.');
      if (role === 'phone') {
        const pc = this.pcs.get(pcId);
        if (!pc) {
          this.log.write('server', 'signal dropped, the PC is offline', { conn: short(connectionId) });
          return;
        }
        pc.send(JSON.stringify({ type: 'signal', sender: connectionId, data: message.data }));
      } else {
        const phone = typeof message.target === 'string' ? this.phones.get(message.target) : undefined;
        if (!phone || phone.target !== pcId) {
          this.log.write('server', 'signal dropped, no such phone', { target: short(message.target) });
          return;
        }
        phone.socket.send(JSON.stringify({ type: 'signal', sender: pcId, data: message.data }));
      }
    });

    ws.on('close', () => {
      clearTimeout(ageLimit);
      if (role === 'phone') {
        this.phones.delete(connectionId);
        this.log.write('server', 'phone left', { conn: short(connectionId) });
        const pc = this.pcs.get(pcId);
        if (pc && pc.readyState === pc.OPEN) pc.send(JSON.stringify({ type: 'peer-left', sender: connectionId }));
      } else if (role === 'pc' && this.pcs.get(pcId) === ws) {
        this.pcs.delete(pcId);
        this.log.write('server', 'pc left', { pc: short(pcId) });
        for (const phone of this.phones.values()) {
          if (phone.target === pcId) phone.socket.send(JSON.stringify({ type: 'remote-offline' }));
        }
      }
    });
    ws.on('error', () => {});
  }
}
