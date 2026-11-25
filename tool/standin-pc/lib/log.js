// One line per event, to stdout and (with --log) appended to a file, like the Flutter app's --loopback-log:
// `<ISO time> <side>: <event> key=value …`.
import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export class Log {
  constructor({ path = null, quiet = false } = {}) {
    this.path = path;
    this.quiet = quiet;
    if (path) mkdirSync(dirname(path), { recursive: true });
  }

  /** `side` is `server`, `pc`, `lan` or `media`; `fields` is written as key=value pairs, strings with spaces quoted. */
  write(side, event, fields = {}) {
    const parts = [new Date().toISOString(), `${side}:`, event];
    for (const [key, value] of Object.entries(fields)) {
      if (value === undefined) continue;
      parts.push(`${key}=${format(value)}`);
    }
    const line = parts.join(' ');
    if (!this.quiet) console.log(line);
    if (this.path) appendFileSync(this.path, line + '\n');
  }
}

function format(value) {
  if (value === null) return 'null';
  if (typeof value === 'object') return JSON.stringify(value);
  const text = String(value);
  return /[\s"]/.test(text) ? JSON.stringify(text) : text;
}

/** The first 8 characters of a random id, as the PC's diagnostics name sessions and phones. */
export const short = (id) => (typeof id === 'string' ? id.slice(0, 8) : String(id));
