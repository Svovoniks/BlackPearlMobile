// The PC's side of the `media-v1` channel (PHONE-REMOTE.md, "The media channel"): the phone asks with text `read`s
// and `cancel`s; the PC answers reads in the order they were asked, each as binary frames of at most 16 KiB of data
// after a 24-byte little-endian header, or a text `read-error`. At most 64 reads wait per phone, past that `busy`.
//
// Frames are sent only while the channel's buffered amount is under `highWater`; past it the sender waits for
// bufferedAmountLow, so a large read (or a phone that reads faster than the link carries) never piles up in memory.

export const frameData = 16 * 1024;
export const headerBytes = 24;
export const maxCount = 262144;
export const maxQueued = 64;

export class ReadError extends Error {
  constructor(code, message, why) {
    super(message);
    this.code = code;
    this.why = why ?? code;
  }
}

export class MediaServer {
  /**
   * @param {object} options
   * @param {import('node-datachannel').DataChannel} options.channel
   * @param {(resource: string) => Promise<{length: number, read: (offset: number, count: number) => Promise<Buffer>}>} options.resolve
   *   finds a resource or throws a ReadError
   * @param {(event: string, fields?: object) => void} options.log
   * @param {boolean} [options.logReads] one log line per read, instead of a summary every 5 seconds
   * @param {number} [options.highWater] bytes buffered on the channel before sending waits (resumes at a quarter of it)
   */
  constructor({ channel, resolve, log, logReads = false, highWater = 1024 * 1024 }) {
    this.channel = channel;
    this.resolve = resolve;
    this.log = log;
    this.logReads = logReads;
    this.highWater = highWater;
    this.queue = [];
    this.active = null;
    this.closed = false;
    this.waiters = [];
    this.stats = { reads: 0, bytes: 0, cancels: 0, errors: 0, busy: 0, maxBuffered: 0, waits: 0 };
    this.reported = '';
    channel.setBufferedAmountLowThreshold(Math.floor(highWater / 4));
    channel.onBufferedAmountLow(() => this.wake());
    this.summary = setInterval(() => this.report(), 5000);
    this.summary.unref?.();
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.summary);
    this.report();
    if (this.active) this.active.cancelled = true;
    this.queue = [];
    this.wake();
  }

  report() {
    const line = JSON.stringify(this.stats);
    if (line === this.reported || this.stats.reads + this.stats.errors + this.stats.busy === 0) return;
    this.reported = line;
    this.log('media summary', { ...this.stats, mib: (this.stats.bytes / 1048576).toFixed(1) });
  }

  wake() {
    const waiters = this.waiters;
    this.waiters = [];
    for (const resolve of waiters) resolve();
  }

  /** Waits until the channel has room, polling as well in case a low-water event came before we started waiting. */
  async room() {
    while (!this.closed) {
      let buffered;
      try {
        buffered = this.channel.bufferedAmount();
      } catch {
        return;
      }
      if (buffered > this.stats.maxBuffered) this.stats.maxBuffered = buffered;
      if (buffered <= this.highWater) return;
      this.stats.waits++;
      await new Promise((resolve) => {
        this.waiters.push(resolve);
        setTimeout(resolve, 100);
      });
    }
  }

  sendText(message) {
    if (this.closed) return;
    try {
      this.channel.sendMessage(JSON.stringify(message));
    } catch {
      // The channel closed under us.
    }
  }

  readError(id, code, message, why) {
    this.stats.errors += code === 'busy' ? 0 : 1;
    if (code === 'busy') this.stats.busy++;
    this.log('read-error', { id, code, why: why ?? code, message });
    this.sendText({ type: 'read-error', id, code, message });
  }

  onMessage(data) {
    if (this.closed || typeof data !== 'string') return;
    let message;
    try {
      message = JSON.parse(data);
    } catch {
      return;
    }
    if (message === null || typeof message !== 'object') return;
    const { id } = message;
    const validId = Number.isInteger(id) && id >= 0 && id <= 0xffffffff;
    if (message.type === 'cancel') {
      if (!validId) return;
      const before = this.queue.length;
      this.queue = this.queue.filter((read) => read.id !== id);
      let cancelled = before !== this.queue.length;
      if (this.active?.id === id) {
        this.active.cancelled = true;
        cancelled = true;
      }
      if (cancelled) this.stats.cancels++;
      if (this.logReads) this.log('cancel', { id, found: cancelled });
      return;
    }
    if (message.type !== 'read') return; // Unknown types are ignored.
    if (!validId) return;
    const { resource, offset, count } = message;
    if (typeof resource !== 'string' || !Number.isSafeInteger(offset) || offset < 0 || !Number.isInteger(count) || count < 1 || count > maxCount) {
      this.readError(id, 'invalid', 'That read isn\'t one the PC understands.', 'malformed');
      return;
    }
    if (this.queue.length + (this.active ? 1 : 0) >= maxQueued) {
      this.readError(id, 'busy', 'The PC has too many reads waiting. Ask again shortly.');
      return;
    }
    this.queue.push({ id, resource, offset, count, cancelled: false });
    if (this.logReads) this.log('read', { id, resource, offset, count, queued: this.queue.length });
    if (!this.active) void this.pump();
  }

  async pump() {
    while (!this.closed && this.queue.length > 0) {
      const read = this.queue.shift();
      this.active = read;
      try {
        await this.answer(read);
      } catch (error) {
        if (error instanceof ReadError) this.readError(read.id, error.code, error.message, error.why);
        else this.readError(read.id, 'failed', 'The PC couldn\'t read that.', `unreadable:${error.message}`);
      }
      this.active = null;
    }
  }

  async answer(read) {
    const source = await this.resolve(read.resource);
    const total = Math.max(0, Math.min(read.count, source.length - read.offset));
    const bytes = total > 0 ? await source.read(read.offset, total) : Buffer.alloc(0);
    if (bytes.length !== total) throw new ReadError('failed', 'The PC couldn\'t read all of that.', 'short-read');
    let sent = 0;
    do {
      await this.room();
      if (this.closed || read.cancelled) return;
      const size = Math.min(frameData, total - sent);
      const frame = Buffer.allocUnsafe(headerBytes + size);
      frame.writeUInt32LE(read.id, 0);
      frame.writeInt32LE(sent, 4);
      frame.writeInt32LE(total, 8);
      frame.writeInt32LE(0, 12);
      frame.writeBigInt64LE(BigInt(source.length), 16);
      bytes.copy(frame, headerBytes, sent, sent + size);
      try {
        this.channel.sendMessageBinary(frame);
      } catch {
        this.close();
        return;
      }
      sent += size;
    } while (sent < total);
    this.stats.reads++;
    this.stats.bytes += total;
  }
}
