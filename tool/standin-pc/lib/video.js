// The one real video every playable library entry maps to: its size, extension and (for Matroska and MP4) duration,
// read without any media tool. Read only, never written.
import { open, readFile, stat } from 'node:fs/promises';
import { extname, join } from 'node:path';

export async function openVideo(path) {
  const info = await stat(path);
  if (!info.isFile()) throw new Error(`${path} is not a file`);
  const handle = await open(path, 'r');
  const durationMs = (await probeDuration(handle, info.size).catch(() => null)) ?? null;
  return {
    path,
    size: info.size,
    extension: extname(path).toLowerCase() || '.mkv',
    durationMs,
    /** Reads `count` bytes at `offset` (fewer at the end of the file). */
    async read(offset, count) {
      const buffer = Buffer.allocUnsafe(count);
      let filled = 0;
      while (filled < count) {
        const { bytesRead } = await handle.read(buffer, filled, count - filled, offset + filled);
        if (bytesRead === 0) break;
        filled += bytesRead;
      }
      return filled === count ? buffer : buffer.subarray(0, filled);
    },
    close: () => handle.close(),
  };
}

/**
 * A conversion the stand-in answers with, made beforehand (README.md): `stream.ts`, the whole video as one piece, and
 * `subtitles.json`, the file's subtitle tracks in order, each `{language, title, codec, burn, file}`; a track with
 * `burn` false is sent from `file`.
 */
export async function openConversion(folder) {
  const stream = await openVideo(join(folder, 'stream.ts'));
  const listed = JSON.parse(await readFile(join(folder, 'subtitles.json'), 'utf8'));
  const subtitles = [];
  for (const [index, track] of listed.entries()) {
    subtitles.push({
      index,
      language: track.language ?? null,
      title: track.title ?? null,
      codec: track.codec ?? 'subrip',
      default: track.default === true,
      forced: track.forced === true,
      burn: track.burn === true,
      bytes: track.burn === true ? null : await readFile(join(folder, track.file)),
    });
  }
  return { stream, subtitles };
}

async function readAt(handle, offset, count) {
  const buffer = Buffer.alloc(count);
  const { bytesRead } = await handle.read(buffer, 0, count, offset);
  return buffer.subarray(0, bytesRead);
}

async function probeDuration(handle, size) {
  const head = await readAt(handle, 0, Math.min(size, 4 * 1024 * 1024));
  return matroskaDuration(head) ?? mp4Duration(head) ?? (size > head.length ? mp4Duration(await readAt(handle, Math.max(0, size - 4 * 1024 * 1024), 4 * 1024 * 1024)) : null);
}

/** EBML variable-length integer at `at`: [value, length], the marker bit removed when `strip`. */
function vint(buffer, at, strip) {
  const first = buffer[at];
  if (first === undefined || first === 0) return null;
  const length = Math.clz32(first) - 23;
  if (at + length > buffer.length) return null;
  let value = strip ? first & (0xff >> length) : first;
  for (let i = 1; i < length; i++) value = value * 256 + buffer[at + i];
  return [value, length];
}

/** Segment › Info › Duration × TimestampScale, in milliseconds. */
function matroskaDuration(buffer) {
  if (buffer.readUInt32BE(0) !== 0x1a45dfa3) return null;
  // Walk the top level: the EBML header, then into the Segment, whose children are skipped by size until Info.
  let at = 0;
  let info = null;
  while (at < buffer.length && info === null) {
    const id = vint(buffer, at, false);
    if (!id) return null;
    const size = vint(buffer, at + id[1], true);
    if (!size) return null;
    const data = at + id[1] + size[1];
    if (id[0] === 0x18538067) at = data; // Segment: step inside
    else if (id[0] === 0x1549a966) info = [data, size[0]];
    else at = data + size[0];
  }
  if (!info) return null;
  at = info[0];
  const end = Math.min(buffer.length, info[0] + info[1]);
  let scale = 1_000_000;
  let duration = null;
  while (at < end) {
    const id = vint(buffer, at, false);
    if (!id) break;
    const length = vint(buffer, at + id[1], true);
    if (!length) break;
    const data = at + id[1] + length[1];
    if (id[0] === 0x2ad7b1) {
      scale = 0;
      for (let i = 0; i < length[0]; i++) scale = scale * 256 + buffer[data + i];
    } else if (id[0] === 0x4489) {
      duration = length[0] === 4 ? buffer.readFloatBE(data) : length[0] === 8 ? buffer.readDoubleBE(data) : null;
    }
    at = data + length[0];
  }
  return duration && scale ? Math.round((duration * scale) / 1e6) : null;
}

/** moov › mvhd duration ÷ timescale, in milliseconds. */
function mp4Duration(buffer) {
  const at = buffer.indexOf(Buffer.from('mvhd'));
  if (at < 0 || at + 32 > buffer.length) return null;
  const version = buffer[at + 4];
  const timescale = version === 1 ? buffer.readUInt32BE(at + 24) : buffer.readUInt32BE(at + 16);
  const duration = version === 1 ? Number(buffer.readBigUInt64BE(at + 28)) : buffer.readUInt32BE(at + 20);
  return timescale ? Math.round((duration * 1000) / timescale) : null;
}
