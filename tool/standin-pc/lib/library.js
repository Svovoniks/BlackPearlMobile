// A small made-up library (PHONE-REMOTE.md, "The library and watching on the phone"): a few films, a show and an anime
// with seasons and episodes, and two saved queues. Every playable entry maps to the one real video file given on the
// command line. Resume points and watched marks are the stand-in PC's own and are kept in the store.
import { createHash } from 'node:crypto';

const films = [
  { slug: 'harbor-lights', title: 'Harbor Lights', year: 2019, overview: 'A lighthouse keeper finds a radio that only plays tomorrow\'s weather.', added: 9 },
  { slug: 'the-long-quiet', title: 'The Long Quiet', year: 2016, overview: 'Two astronomers wait out a winter at a station with no signal.', added: 3 },
  { slug: 'paper-tigers', title: 'Paper Tigers', year: 2022, overview: 'A forger is hired to fake the one painting she can\'t stand.', added: 12 },
  { slug: 'last-train-east', title: 'Last Train East', year: 2014, overview: 'Strangers share the last carriage before the line closes for good.', added: 1 },
  { slug: 'glass-orchard', title: 'Glass Orchard', year: 2023, overview: 'An orchard that grows glass apples, and the family that sells them.', added: 14 },
];

const shows = [
  {
    slug: 'night-signal',
    title: 'Night Signal',
    kind: 'Show',
    year: 2021,
    overview: 'A late-night radio host starts getting calls from listeners who haven\'t been born yet.',
    added: 10,
    seasons: [
      ['Dead Air', 'Static', 'Call-In', 'Low Tide'],
      ['Frequency', 'Night Shift', 'Low Tide', 'Interference', 'Sign Off'],
    ],
  },
  {
    slug: 'paper-comets',
    title: 'Paper Comets',
    kind: 'Anime',
    year: 2023,
    overview: 'Three students build a rocket out of a school newspaper\'s old presses.',
    added: 13,
    seasons: [['Launch Window', 'Ink and Fuel', 'Countdown']],
  },
  {
    slug: 'midnight-ledger',
    title: 'The Midnight Ledger',
    kind: 'Show',
    year: 2018,
    overview: 'An accountant audits a city that keeps its books in dreams.',
    added: 5,
    seasons: [['Opening Balance', 'Red Ink']],
  },
];

const categoryKinds = { 0: null, 1: ['Movie'], 2: ['Show'], 3: ['Anime'], 6: ['Music'] };
const categoryNames = { 0: 'All titles', 1: 'Films', 2: 'Shows', 3: 'Anime', 6: 'Music' };
const pageSize = 40;

export class LibraryError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function token(id) {
  return createHash('sha256').update(`art:${id}`).digest('hex').slice(0, 24);
}

/** A small seeded random generator (mulberry32), so Home's suggestions shuffle the same way for the same seed. */
function random(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function shuffled(list, seed) {
  const next = random(seed);
  const copy = [...list];
  for (let i = copy.length - 1; i > 0; i--) {
    const j = Math.floor(next() * (i + 1));
    [copy[i], copy[j]] = [copy[j], copy[i]];
  }
  return copy;
}

/** The stream id of the `--conversion`. */
export const conversionStreamId = 'c0'.repeat(16);

export class Library {
  /**
   * @param {object} options
   * @param {{size:number, extension:string, durationMs:number|null}} options.video
   * @param {import('./store.js').Store} options.store
   * @param {{stream: {size:number}, subtitles: object[]}|null} [options.conversion] what a watch asking for a conversion gets
   */
  constructor({ video, store, conversion = null }) {
    this.video = video;
    this.conversion = conversion;
    this.store = store;
    this.durationMs = video.durationMs && video.durationMs > 0 ? video.durationMs : 24 * 60 * 1000;
    this.runtimeMinutes = Math.max(1, Math.round(this.durationMs / 60000));
    /** id → item. Items: films, shows (series), episodes. */
    this.items = new Map();
    /** art token → { width, height } natural size. */
    this.pictures = new Map();
    this.titles = [];
    for (const film of films) {
      const item = { ...film, id: `film-${film.slug}`, type: 'movie', kind: 'Movie', artwork: token(`film-${film.slug}`) };
      this.items.set(item.id, item);
      this.titles.push(item);
      this.pictures.set(item.artwork, { width: 600, height: 900 });
    }
    for (const show of shows) {
      const item = { ...show, id: `show-${show.slug}`, type: 'series', artwork: token(`show-${show.slug}`), episodeIds: [] };
      this.pictures.set(item.artwork, { width: 600, height: 900 });
      this.items.set(item.id, item);
      this.titles.push(item);
      show.seasons.forEach((titles, s) => {
        titles.forEach((title, e) => {
          const id = `${item.id}-s${s + 1}e${e + 1}`;
          const episode = { id, type: 'episode', kind: show.kind, title, show: item, season: s + 1, episode: e + 1, year: show.year, artwork: token(id) };
          this.pictures.set(episode.artwork, { width: 640, height: 360 });
          this.items.set(id, episode);
          item.episodeIds.push(id);
        });
      });
    }
    this.queues = [
      { id: 'queue-evening', name: 'Evening', places: ['film-harbor-lights', 'show-night-signal-s1e3', 'film-gone-missing', 'show-night-signal-s1e4', 'film-paper-tigers'] },
      { id: 'queue-weekend', name: 'Weekend marathon', places: ['show-paper-comets-s1e1', 'show-paper-comets-s1e2', 'show-paper-comets-s1e3', 'film-last-train-east'] },
    ];
    if (!store.data.playback) {
      // First run: something to continue, and a few watched marks.
      const now = Date.now();
      store.data.playback = {
        'show-night-signal-s1e1': { positionMs: 0, watched: true, playedAt: now - 3 * 86400000 },
        'show-night-signal-s1e2': { positionMs: Math.round(this.durationMs * 0.4), watched: false, playedAt: now - 3600000 },
        'film-the-long-quiet': { positionMs: Math.round(this.durationMs * 0.7), watched: false, playedAt: now - 2 * 86400000 },
        'film-last-train-east': { positionMs: 0, watched: true, playedAt: now - 9 * 86400000 },
      };
      store.save();
    }
  }

  get playback() {
    return this.store.data.playback;
  }

  playbackOf(id) {
    return this.playback[id] ?? { positionMs: 0, watched: false, playedAt: 0 };
  }

  /** A film or an episode. */
  playable(id) {
    const item = this.items.get(id);
    return item && (item.type === 'movie' || item.type === 'episode') ? item : null;
  }

  started(item) {
    if (item.type === 'series') return item.episodeIds.some((id) => this.started(this.items.get(id)));
    const playback = this.playbackOf(item.id);
    return playback.watched || playback.positionMs > 0;
  }

  watchedAll(ids) {
    return ids.length > 0 && ids.every((id) => this.playbackOf(id).watched);
  }

  episodeDetail(episode, withTitle) {
    return `Season ${episode.season} · Episode ${episode.episode}${withTitle ? ` · ${episode.title}` : ''}`;
  }

  /** What the PC's player shows for a video: [title, detail]. */
  describe(item) {
    return item.type === 'episode' ? [item.show.title, this.episodeDetail(item, true)] : [item.title, `${item.year}`];
  }

  entry(item, extra = {}) {
    const base = {
      id: item.id,
      title: item.title,
      caption: '',
      level: 'movie',
      season: null,
      episode: null,
      overview: item.overview ?? '',
      kind: item.kind,
      runtimeMinutes: null,
      year: item.year ?? null,
      episodes: 0,
      homeSection: null,
      positionMs: 0,
      watched: false,
      artwork: item.artwork,
      playable: false,
    };
    if (item.type === 'movie') {
      const playback = this.playbackOf(item.id);
      Object.assign(base, { caption: `Film · ${item.year}`, runtimeMinutes: this.runtimeMinutes, positionMs: playback.positionMs, watched: playback.watched, playable: true });
    } else if (item.type === 'series') {
      Object.assign(base, { caption: `${item.kind} · ${item.year}`, level: 'series', episodes: item.episodeIds.length, watched: this.watchedAll(item.episodeIds) });
    } else if (item.type === 'episode') {
      const playback = this.playbackOf(item.id);
      Object.assign(base, {
        caption: this.episodeDetail(item, false),
        level: 'episode',
        season: item.season,
        episode: item.episode,
        overview: `${item.show.title}, season ${item.season}.`,
        runtimeMinutes: this.runtimeMinutes,
        positionMs: playback.positionMs,
        watched: playback.watched,
        playable: true,
      });
    }
    return { ...base, ...extra };
  }

  seasonEntry(show, season) {
    const ids = show.episodeIds.filter((id) => this.items.get(id).season === season);
    return {
      ...this.entry(show),
      title: `Season ${season}`,
      caption: `${ids.length} episodes`,
      level: 'season',
      season,
      episodes: ids.length,
      watched: this.watchedAll(ids),
    };
  }

  /** A Continue watching card: for an episode, the show's card naming the episode to resume. */
  continueEntry(item) {
    if (item.type !== 'episode') return this.entry(item, { homeSection: 'continue' });
    const playback = this.playbackOf(item.id);
    return {
      ...this.entry(item.show),
      id: item.id,
      caption: this.episodeDetail(item, true),
      runtimeMinutes: this.runtimeMinutes,
      positionMs: playback.positionMs,
      watched: false,
      artwork: item.artwork,
      playable: true,
      homeSection: 'continue',
    };
  }

  page(request, entries, location) {
    const page = Number.isInteger(request.page) && request.page >= 0 ? request.page : 0;
    return {
      type: 'page',
      request: request.request,
      total: entries.length,
      page,
      pageSize,
      location,
      entries: entries.slice(page * pageSize, (page + 1) * pageSize),
    };
  }

  /** Answers a `browse` with a `page`, or throws a LibraryError with code `browse`. */
  browse(request) {
    const query = typeof request.query === 'string' ? request.query.trim().toLowerCase() : '';
    if (typeof request.queue === 'string') {
      const queue = this.queues.find((q) => q.id === request.queue);
      if (!queue) throw new LibraryError('browse', 'That queue is gone.');
      const entries = [];
      queue.places.forEach((id, index) => {
        const item = this.playable(id);
        if (item) entries.push(this.entry(item, { index }));
      });
      return this.page(request, entries, queue.name);
    }
    if (typeof request.episodesOf === 'string') {
      const item = this.items.get(request.episodesOf);
      const show = item?.type === 'series' ? item : item?.type === 'episode' ? item.show : null;
      if (!show) throw new LibraryError('browse', 'That show is gone.');
      return this.page(request, show.episodeIds.map((id, index) => this.entry(this.items.get(id), { index })), show.title);
    }
    if (request.parentId != null) {
      const show = this.items.get(request.parentId);
      if (show?.type !== 'series') throw new LibraryError('browse', 'That show is gone.');
      if (Number.isInteger(request.season)) {
        const episodes = show.episodeIds.map((id) => this.items.get(id)).filter((e) => e.season === request.season);
        if (episodes.length === 0) throw new LibraryError('browse', 'That season is gone.');
        return this.page(request, episodes.map((e) => this.entry(e)), `${show.title} · Season ${request.season}`);
      }
      const seasons = [...new Set(show.episodeIds.map((id) => this.items.get(id).season))];
      return this.page(request, seasons.map((s) => this.seasonEntry(show, s)), show.title);
    }
    if (request.home === true) return this.page(request, this.home(Number(request.seed) || 0), 'Home');
    if (request.unwatched === true) {
      return this.page(request, this.unwatchedTitles().map((item) => this.entry(item)), 'Unwatched');
    }
    const kinds = categoryKinds[request.category] ?? null;
    const matches = this.titles
      .filter((item) => !kinds || kinds.includes(item.kind))
      .filter((item) => !query || item.title.toLowerCase().includes(query))
      .sort((a, b) => a.title.localeCompare(b.title));
    const location = query ? `Results for “${request.query.trim()}”` : (categoryNames[request.category] ?? 'All titles');
    return this.page(request, matches.map((item) => this.entry(item)), location);
  }

  /** Titles not started yet, newest first. */
  unwatchedTitles() {
    return this.titles.filter((item) => !this.started(item)).sort((a, b) => b.added - a.added);
  }

  /** Home: Continue watching, suggestions for each kind (shuffled by seed), one random pick, then up to 30 unwatched. */
  home(seed) {
    const entries = [];
    const continuing = Object.entries(this.playback)
      .filter(([id, p]) => this.playable(id) && !p.watched && p.positionMs > 0)
      .sort((a, b) => b[1].playedAt - a[1].playedAt)
      .slice(0, 20);
    for (const [id] of continuing) entries.push(this.continueEntry(this.playable(id)));
    for (const kind of ['Movie', 'Show', 'Anime']) {
      const fresh = this.titles.filter((item) => item.kind === kind && !this.started(item));
      for (const item of shuffled(fresh, seed + kind.length).slice(0, 10)) entries.push(this.entry(item, { homeSection: 'suggestions' }));
    }
    const pickable = this.titles.filter((item) => item.type === 'movie' && !this.playbackOf(item.id).watched);
    if (pickable.length > 0) entries.push(this.entry(shuffled(pickable, seed)[0], { homeSection: 'mystery' }));
    for (const item of this.unwatchedTitles().slice(0, 30)) entries.push(this.entry(item, { homeSection: 'unwatched' }));
    return entries;
  }

  /** The saved queues, with the PC's active one marked. `active`: { id, index } of what the PC plays, or null. */
  queueList(active) {
    return this.queues.map((queue) => {
      const present = queue.places.map((id, index) => [id, index]).filter(([id]) => this.playable(id));
      const isActive = active?.id === queue.id;
      const firstUnwatched = present.find(([id]) => !this.playbackOf(id).watched);
      return {
        id: queue.id,
        name: queue.name,
        count: present.length,
        upNext: isActive && Number.isInteger(active.index) ? active.index : (firstUnwatched?.[1] ?? null),
        active: isActive,
        artwork: present.length > 0 ? this.items.get(present[0][0]).artwork : null,
      };
    });
  }

  step(item, queueIndex) {
    if (!item) return null;
    const detail = item.type === 'episode' ? this.episodeDetail(item, false) : `${item.year}`;
    return { id: item.id, title: item.title, detail, ...(queueIndex == null ? {} : { queueIndex }) };
  }

  /**
   * Where a video sits for Previous and Next: in a saved queue (falling back to the video's first place there, and to
   * the show's episodes when the queue doesn't have it), else among its show's episodes. Returns
   * { queue: {id,name,index}|null, previous, next, first } with each step an item and its place.
   */
  context(item, queueId, queueIndex) {
    const queue = typeof queueId === 'string' ? this.queues.find((q) => q.id === queueId) : null;
    if (queue) {
      let index = Number.isInteger(queueIndex) && queue.places[queueIndex] === item.id ? queueIndex : queue.places.indexOf(item.id);
      if (index >= 0) {
        const around = (from, direction) => {
          for (let i = from + direction; i >= 0 && i < queue.places.length; i += direction) {
            if (this.playable(queue.places[i])) return [this.playable(queue.places[i]), i];
          }
          return null;
        };
        const firstPlace = around(-1, 1);
        return { queue: { id: queue.id, name: queue.name, index }, previous: around(index, -1), next: around(index, 1), first: firstPlace };
      }
    }
    if (item.type === 'episode') {
      const ids = item.show.episodeIds;
      const at = ids.indexOf(item.id);
      const of = (i) => (i >= 0 && i < ids.length ? [this.items.get(ids[i]), null] : null);
      return { queue: null, previous: of(at - 1), next: of(at + 1), first: of(0) };
    }
    return { queue: null, previous: null, next: null, first: null };
  }

  /**
   * Answers a `watch` with a `stream` for the file itself, or with the `--conversion` when it asks for one; throws a
   * LibraryError with code `gone`.
   */
  watch(request) {
    const item = this.playable(request.id);
    if (!item) throw new LibraryError('gone', 'That video isn\'t in the library any more.');
    const playback = this.playbackOf(item.id);
    const context = this.context(item, request.queue, request.queueIndex);
    const [title] = this.describe(item);
    const quality = typeof request.quality === 'string' ? request.quality : 'auto';
    const wantedConversion = quality !== 'original' && !(quality === 'auto' && (request.network ?? 'home') === 'home');
    const stream = {
      type: 'stream',
      request: request.request,
      id: item.id,
      title,
      detail: item.type === 'episode' ? this.episodeDetail(item, false) : null,
      positionMs: playback.watched ? 0 : playback.positionMs,
      durationMs: this.durationMs,
      kind: 'file',
      resource: `file/${item.id}`,
      length: this.video.size,
      extension: this.video.extension,
      quality: 'original',
      qualities: this.conversion ? ['original', '480p'] : ['original'],
      note: wantedConversion ? 'This stand-in PC has no converter, so it sent the file itself.' : null,
      previous: context.previous ? this.step(...context.previous) : null,
      next: context.next ? this.step(...context.next) : null,
      first: !context.next && context.first && (item.type === 'episode' || context.queue) ? this.step(...context.first) : null,
      tracks: { audio: ['ja', 'en'], subtitles: ['en'], rules: [{ audio: 'en', languages: ['off'] }] },
    };
    if (context.queue) stream.queue = context.queue;
    if (wantedConversion && this.conversion) return this.converted(stream, request);
    return stream;
  }

  /** The `--conversion` as a one-piece conversion, with its subtitles: the one asked for (-1: none), else the first. */
  converted(stream, request) {
    const subtitles = this.conversion.subtitles;
    const asked = Number.isInteger(request.subtitle) ? request.subtitle : null;
    const shown = asked === null ? (subtitles.length > 0 ? 0 : null) : asked >= 0 && asked < subtitles.length ? asked : null;
    const converted = { ...stream, kind: 'hls', streamId: conversionStreamId, segments: 1, segmentMs: this.durationMs, quality: '480p', qualities: ['original', '480p'], note: null };
    delete converted.resource;
    delete converted.length;
    delete converted.extension;
    return {
      ...converted,
      audioTracks: [{ index: 0, language: 'jpn', title: null, codec: 'aac', layout: 'stereo' }],
      audioTrack: 0,
      subtitleTracks: subtitles.map(({ bytes, ...track }) => track),
      subtitleTrack: shown,
    };
  }

  /**
   * A `progress` report: saved as the PC's own playback. Watched once within 2 s of the end, or `ended` within the last
   * minute (anywhere when durationMs is 0), or a `final` report in the last tenth.
   */
  progress(report) {
    const item = this.playable(report.id);
    if (!item || typeof report.positionMs !== 'number') return false;
    const position = Math.max(0, Math.round(report.positionMs));
    const duration = typeof report.durationMs === 'number' ? Math.max(0, report.durationMs) : 0;
    const watched =
      (duration > 0 && position >= duration - 2000) ||
      (report.ended === true && (duration === 0 || position >= duration - 60000)) ||
      (report.final === true && duration > 0 && position >= duration * 0.9);
    const previous = this.playbackOf(item.id);
    this.playback[item.id] = { positionMs: watched ? 0 : position, watched: watched || previous.watched, playedAt: Date.now() };
    this.store.save();
    return true;
  }

  /** `mark-watched`: throws LibraryError `invalid` or `gone`. */
  markWatched(request) {
    const level = request.level;
    if (!['movie', 'episode', 'series', 'season'].includes(level) || typeof request.watched !== 'boolean') {
      throw new LibraryError('invalid', 'The PC couldn\'t understand that mark.');
    }
    const item = this.items.get(request.id);
    let ids;
    if (level === 'movie' || level === 'episode') {
      if (!item || item.type !== level) throw new LibraryError('gone', 'That title isn\'t in the library any more.');
      ids = [item.id];
    } else {
      const show = item?.type === 'series' ? item : item?.type === 'episode' ? item.show : null;
      if (!show) throw new LibraryError('gone', 'That title isn\'t in the library any more.');
      ids = show.episodeIds;
      if (level === 'season') {
        if (!Number.isInteger(request.season)) throw new LibraryError('invalid', 'The PC couldn\'t understand that mark.');
        ids = ids.filter((id) => this.items.get(id).season === request.season);
        if (ids.length === 0) throw new LibraryError('gone', 'That season isn\'t in the library any more.');
      }
    }
    for (const id of ids) {
      const previous = this.playbackOf(id);
      this.playback[id] = { positionMs: request.watched ? 0 : previous.positionMs, watched: request.watched, playedAt: previous.playedAt || Date.now() };
    }
    this.store.save();
    return ids.length;
  }
}
