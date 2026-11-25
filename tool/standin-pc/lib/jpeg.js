// Made-up pictures for `art/<token>/<width>`: a tiny baseline JPEG encoder that writes only each 8×8 block's average
// (DC coefficients, no AC), so a poster is a soft blocky gradient. No image library needed, and any JPEG decoder reads
// it: 4:4:4 YCbCr, one quantisation table of 8s, a DC Huffman table (the standard luminance one) and an AC table that
// holds only end-of-block.
import { createHash } from 'node:crypto';

const dcBits = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const dcValues = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const acBits = [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
const acValues = [0x00]; // EOB only

/** Canonical Huffman codes from a BITS list: symbol → [code, length]. */
function huffmanCodes(bits, values) {
  const codes = new Map();
  let code = 0;
  let k = 0;
  for (let length = 1; length <= 16; length++) {
    for (let i = 0; i < bits[length - 1]; i++) codes.set(values[k++], [code++, length]);
    code <<= 1;
  }
  return codes;
}
const dcCodes = huffmanCodes(dcBits, dcValues);
const [eobCode, eobLength] = huffmanCodes(acBits, acValues).get(0);

class BitWriter {
  constructor() {
    this.bytes = [];
    this.buffer = 0;
    this.count = 0;
  }
  write(value, length) {
    for (let i = length - 1; i >= 0; i--) {
      this.buffer = (this.buffer << 1) | ((value >> i) & 1);
      if (++this.count === 8) this.flushByte();
    }
  }
  flushByte() {
    this.bytes.push(this.buffer);
    if (this.buffer === 0xff) this.bytes.push(0x00); // byte stuffing
    this.buffer = 0;
    this.count = 0;
  }
  finish() {
    if (this.count > 0) {
      this.buffer = (this.buffer << (8 - this.count)) | ((1 << (8 - this.count)) - 1); // pad with 1s
      this.count = 8;
      this.flushByte();
    }
    return Buffer.from(this.bytes);
  }
}

function segment(marker, body) {
  const head = Buffer.from([0xff, marker, ((body.length + 2) >> 8) & 0xff, (body.length + 2) & 0xff]);
  return Buffer.concat([head, Buffer.from(body)]);
}

/**
 * Encodes a picture whose every 8×8 block has one colour. `blockColor(bx, by)` returns [r, g, b] in 0–255.
 */
export function encodeBlocks(width, height, blockColor) {
  const blocksX = Math.ceil(width / 8);
  const blocksY = Math.ceil(height / 8);
  const bits = new BitWriter();
  const predictors = [0, 0, 0];
  for (let by = 0; by < blocksY; by++) {
    for (let bx = 0; bx < blocksX; bx++) {
      const [r, g, b] = blockColor(bx, by);
      const y = 0.299 * r + 0.587 * g + 0.114 * b;
      const cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b;
      const cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b;
      const components = [y, cb, cr];
      for (let c = 0; c < 3; c++) {
        // DC = 8 × (mean − 128); quantised by 8 it is the level-shifted mean itself.
        const dc = Math.max(-128, Math.min(127, Math.round(components[c] - 128)));
        const diff = dc - predictors[c];
        predictors[c] = dc;
        const magnitude = Math.abs(diff);
        const category = magnitude === 0 ? 0 : 32 - Math.clz32(magnitude);
        const [code, length] = dcCodes.get(category);
        bits.write(code, length);
        if (category > 0) bits.write(diff > 0 ? diff : diff + (1 << category) - 1, category);
        bits.write(eobCode, eobLength);
      }
    }
  }
  const scan = bits.finish();
  const quant = [0x00, ...new Array(64).fill(8)];
  const frame = [8, height >> 8, height & 0xff, width >> 8, width & 0xff, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0];
  const huffman = [0x00, ...dcBits, ...dcValues, 0x10, ...acBits, ...acValues];
  const scanHeader = [3, 1, 0x00, 2, 0x00, 3, 0x00, 0, 63, 0];
  return Buffer.concat([
    Buffer.from([0xff, 0xd8]),
    segment(0xe0, [0x4a, 0x46, 0x49, 0x46, 0x00, 1, 1, 0, 0, 1, 0, 1, 0, 0]),
    segment(0xdb, quant),
    segment(0xc0, frame),
    segment(0xc4, huffman),
    segment(0xda, scanHeader),
    scan,
    Buffer.from([0xff, 0xd9]),
  ]);
}

function hsl(h, s, l) {
  const a = s * Math.min(l, 1 - l);
  const f = (n) => {
    const k = (n + h / 30) % 12;
    return Math.round(255 * (l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1))));
  };
  return [f(0), f(8), f(4)];
}

/**
 * A made-up picture for `token`, `naturalWidth`×`naturalHeight` at most `width` wide (never enlarged): a diagonal
 * gradient in two hues the token picks, with a lighter band across it.
 */
export function makePicture(token, width, naturalWidth, naturalHeight) {
  const w = Math.max(8, Math.min(width, naturalWidth));
  const h = Math.max(8, Math.round((naturalHeight * w) / naturalWidth));
  const seed = createHash('sha256').update(token).digest();
  const hue1 = (seed[0] / 255) * 360;
  const hue2 = (hue1 + 40 + (seed[1] / 255) * 120) % 360;
  const blocksX = Math.ceil(w / 8);
  const blocksY = Math.ceil(h / 8);
  const band = 0.55 + (seed[2] / 255) * 0.2;
  return encodeBlocks(w, h, (bx, by) => {
    const t = (bx / blocksX + by / blocksY) / 2;
    const v = by / blocksY;
    const light = Math.abs(v - band) < 0.06 ? 0.72 : 0.25 + 0.3 * (1 - t);
    return hsl(t < 0.5 ? hue1 : hue2, 0.55, light);
  });
}
