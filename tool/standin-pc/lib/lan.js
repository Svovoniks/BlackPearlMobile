// The PC's home-network socket (PHONE-REMOTE.md, "On the home network"): `ws://<address>:<port>/remote`, the room
// server's protocol for this PC's id only, each connection handed its own session id, signals signed `phone-lan` /
// `pc-lan`. Port 47830, or the next free one up to 47839.
import { createServer } from 'node:http';
import { WebSocketServer } from 'ws';
import { lanSession, randomHex } from './signing.js';
import { short } from './log.js';

const maxConnections = 8;
const maxMessage = 64 * 1024;

export class LanListener {
  /**
   * @param {object} options
   * @param {import('./standin-pc.js').StandinPc} options.pc
   * @param {import('./log.js').Log} options.log
   * @param {string} options.bind the address to listen on
   * @param {string[]} options.addresses what the PC's welcome tells phones (10.0.2.2 for the emulator)
   */
  constructor({ pc, log, bind, addresses, firstPort = 47830, lastPort = 47839 }) {
    this.pc = pc;
    this.log = log;
    this.bind = bind;
    this.addresses = addresses;
    this.firstPort = firstPort;
    this.lastPort = lastPort;
    this.connections = new Set();
    this.http = null;
  }

  async start() {
    for (let port = this.firstPort; port <= this.lastPort; port++) {
      const http = createServer((request, response) => {
        response.writeHead(404);
        response.end();
      });
      http.maxHeaderSize = 8 * 1024;
      const ok = await new Promise((resolve) => {
        http.once('error', () => resolve(false));
        http.listen(port, this.bind, () => resolve(true));
      });
      if (!ok) continue;
      this.http = http;
      const wss = new WebSocketServer({ noServer: true, maxPayload: maxMessage, perMessageDeflate: false });
      http.on('upgrade', (request, socket, head) => {
        if (new URL(request.url, 'http://x').pathname !== '/remote') {
          socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
          return;
        }
        if (this.connections.size >= maxConnections) {
          this.log.write('lan', 'refused', { reason: 'too-many-connections' });
          socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
          return;
        }
        wss.handleUpgrade(request, socket, head, (ws) => this.accept(ws));
      });
      this.port = port;
      this.pc.lan = { port, addresses: this.addresses };
      this.log.write('lan', 'started', { port, moved: port !== this.firstPort, bind: this.bind, addresses: this.addresses.join(',') });
      return port;
    }
    this.log.write('lan', 'busy', { from: this.firstPort, to: this.lastPort });
    return null;
  }

  close() {
    for (const connection of this.connections) connection.ws.terminate();
    this.pc.lan = null;
    return new Promise((resolve) => (this.http ? this.http.close(() => resolve()) : resolve()));
  }

  accept(ws) {
    const connection = { ws, id: randomHex(4), session: null, proven: false };
    this.connections.add(connection);
    const send = (message) => ws.readyState === ws.OPEN && ws.send(JSON.stringify(message));
    const fail = (text, reason) => {
      this.log.write('lan', 'refused', { conn: connection.id, reason });
      send({ type: 'error', text });
      ws.close(1008, 'error');
    };
    const greet = setTimeout(() => connection.session || fail('Say remote-phone first.', 'bad-request'), 10000);
    const unproven = setTimeout(() => connection.proven || fail('This connection didn\'t prove itself in time.', 'unproven'), 30000);
    this.log.write('lan', 'opened', { conn: connection.id });
    ws.on('message', (data, isBinary) => {
      if (isBinary) return fail('Binary messages are not supported.', 'bad-request');
      let message;
      try {
        message = JSON.parse(data.toString('utf8'));
      } catch {
        return fail('Unreadable message.', 'bad-request');
      }
      if (message?.type === 'ping') return send({ type: 'pong', number: message.number, data: String(Date.now()) });
      if (!connection.session) {
        if (message?.type !== 'remote-phone') return fail('Say remote-phone first.', 'bad-request');
        if (message.number !== 1) return fail(message.number > 1 ? 'This PC speaks phone remote version 1. Update BlackPearl on the PC.' : 'This PC speaks phone remote version 1. Update the phone app.', 'protocol');
        if (typeof message.target !== 'string' || message.target.toUpperCase() !== this.pc.pcId) return fail('This is another PC.', 'wrong-pc');
        connection.session = lanSession(this.pc.hostKey);
        send({ type: 'remote-welcome', target: connection.id, data: JSON.stringify({ iceServers: [], forceRelay: false, session: connection.session }) });
        send({ type: 'remote-online' });
        this.log.write('lan', 'greeted', { conn: connection.id, session: short(connection.session) });
        return;
      }
      if (message?.type !== 'signal' || typeof message.data !== 'string') return;
      const verified = this.pc.handleSignal(message.data, {
        via: 'lan',
        session: connection.session,
        reply: (text) => send({ type: 'signal', data: text }),
      });
      if (verified && !connection.proven) {
        connection.proven = true;
        this.log.write('lan', 'proven', { conn: connection.id });
      }
    });
    ws.on('close', () => {
      clearTimeout(greet);
      clearTimeout(unproven);
      this.connections.delete(connection);
      this.log.write('lan', 'closed', { conn: connection.id, proven: connection.proven });
    });
    ws.on('error', () => {});
  }
}
