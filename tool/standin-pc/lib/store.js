// What the stand-in PC keeps between runs, in one JSON file: its host key (so its PC id stays the same and a paired
// phone finds it again), its name, the paired phones' ids and secrets, and the library's resume points and watched marks.
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomHex } from './signing.js';

export class Store {
  constructor(path) {
    this.path = path;
    let data = {};
    if (existsSync(path)) {
      try {
        data = JSON.parse(readFileSync(path, 'utf8'));
      } catch (error) {
        throw new Error(`Couldn't read ${path}: ${error.message}. Delete it to start over (paired phones must pair again).`);
      }
    }
    this.data = {
      hostKey: typeof data.hostKey === 'string' && /^[0-9a-f]{64}$/i.test(data.hostKey) ? data.hostKey : randomHex(32),
      name: typeof data.name === 'string' ? data.name : null,
      /** phone id (lower case) → { secret, name, pairedAt } */
      phones: data.phones && typeof data.phones === 'object' ? data.phones : {},
      /** library id → { positionMs, watched, playedAt } */
      playback: data.playback && typeof data.playback === 'object' ? data.playback : null,
    };
    this.timer = null;
    this.saveNow();
  }

  get hostKey() {
    return this.data.hostKey;
  }

  /** Saves soon, coalescing bursts (progress reports, marks). */
  save() {
    if (this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.saveNow();
    }, 300);
  }

  saveNow() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    mkdirSync(dirname(this.path), { recursive: true });
    const temporary = `${this.path}.tmp`;
    writeFileSync(temporary, JSON.stringify(this.data, null, 2));
    renameSync(temporary, this.path);
  }
}
