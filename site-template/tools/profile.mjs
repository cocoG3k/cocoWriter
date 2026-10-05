import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import YAML from 'yaml';
import { parse as parseTOML } from 'smol-toml';

export const defaultProfile = JSON.parse(await readFile(fileURLToPath(new URL('../blog-profile.json', import.meta.url)), 'utf8'));
const safePath = (path, empty = false) => typeof path === 'string' && (empty && path === '' || path.split('/').every(p => p && p !== '.' && p !== '..' && /^[\p{L}\p{N}_.-]+$/u.test(p)));
export function validateProfile(p) {
  if (p.schemaVersion !== 1 || !safePath(p.articleDirectory, true) || !safePath(p.imageDirectory, true)
    || typeof p.imagePublicPath !== 'string' || !p.imagePublicPath.startsWith('/')
    || !(p.imagePublicPath === '/' || safePath(p.imagePublicPath.slice(1)))) throw new Error('Invalid blog profile paths or schema');
  if (!Array.isArray(p.articleExtensions) || !p.articleExtensions.length || p.articleExtensions.some(x => !['md', 'markdown'].includes(x))
    || new Set(p.articleExtensions).size !== p.articleExtensions.length
    || !Array.isArray(p.excludedArticleNames) || p.excludedArticleNames.some(x => !safePath(x) || x.includes('/'))) throw new Error('Invalid article extensions or exclusions');
  const name = typeof p.filenameTemplate === 'string' ? p.filenameTemplate.replaceAll(/\{(id|date|year|month|day)\}/g, '01') : '';
  if (p.filenameTemplate?.split('{id}').length !== 2 || !safePath(name) || !p.articleExtensions.includes(name.split('.').at(-1))) throw new Error('Invalid filename template');
  if (!['site-relative', 'absolute'].includes(p.imageReferenceStyle)) throw new Error('Invalid image reference style');
  const f = p.frontMatter;
  if (!f || !['yaml', 'toml', 'json'].includes(f.format) || !['date', 'iso8601', 'jekyll'].includes(f.dateStyle)
    || typeof f.requireDescription !== 'boolean' || typeof f.fields?.title !== 'string' || typeof f.fields?.date !== 'string'
    || ![null, 'string'].includes(f.fields?.description == null ? null : typeof f.fields.description)
    || ![null, 'string'].includes(f.fields?.tags == null ? null : typeof f.fields.tags)
    || f.requireDescription && !f.fields.description || !f.extra || typeof f.extra !== 'object' || Array.isArray(f.extra)) throw new Error('Invalid front matter configuration');
  new Intl.DateTimeFormat('en', { timeZone: f.timeZone }).format(new Date());
  const keys = [f.fields.title, f.fields.description, f.fields.date, f.fields.tags].filter(x => x != null);
  const extras = Object.keys(f.extra);
  if (new Set(keys).size !== keys.length || [...keys, ...extras].some(x => !/^[A-Za-z_][A-Za-z0-9_-]*$/.test(x))
    || extras.some(x => keys.includes(x)) || Object.values(f.extra).some(x => !(typeof x === 'string' || typeof x === 'boolean'
      || typeof x === 'number' && Number.isFinite(x) && Math.abs(x) <= Number.MAX_SAFE_INTEGER || Array.isArray(x) && x.every(t => typeof t === 'string')))) throw new Error('Invalid fields or extra values');
  return p;
}

export function imageRepositoryPath(src, profile, websiteURLs = []) {
  if (profile.imageReferenceStyle === 'absolute') {
    const bases = Array.isArray(websiteURLs) ? websiteURLs : [websiteURLs];
    const base = [...bases].sort((a, b) => b.length - a.length).find(url => src.startsWith(url.endsWith('/') ? url : url + '/'));
    if (!base) return null;
    src = '/' + src.slice(base.endsWith('/') ? base.length : base.length + 1);
  }
  const prefix = (profile.imagePublicPath === '/' ? '' : profile.imagePublicPath) + '/';
  if (!src.startsWith(prefix)) return null;
  const suffix = src.slice(prefix.length);
  if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\/[0-9a-f]{64}\.jpg$/i.test(suffix)) return null;
  return (profile.imageDirectory ? profile.imageDirectory + '/' : '') + suffix;
}

function jsonEnd(text) {
  let depth = 0, quoted = false, escaped = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (escaped) escaped = false;
      else if (c === '\\') escaped = true;
      else if (c === '"') quoted = false;
    } else if (c === '"') quoted = true;
    else if (c === '{') depth++;
    else if (c === '}' && --depth === 0) return i + 1;
  }
  throw new Error('Unclosed JSON front matter');
}

export function parseContent(source, path, profile = defaultProfile) {
  let data, body;
  const match = source.match(/^(---|\+\+\+)\r?\n([\s\S]*?)\r?\n\1(?:\r?\n|$)([\s\S]*)$/);
  if (match) { data = match[1] === '---' ? YAML.parse(match[2]) : parseTOML(match[2], { unsafeKeyBehaviour: 'throw' }); body = match[3]; }
  else if (source.startsWith('{')) { const end = jsonEnd(source); data = JSON.parse(source.slice(0, end)); body = source.slice(end).replace(/^\r?\n/, ''); }
  else throw new Error(`${path}: YAML, TOML or JSON front matter is required`);
  const fields = profile.frontMatter.fields;
  const title = data?.[fields.title], description = fields.description ? data?.[fields.description] ?? '' : '';
  const rawDate = data?.[fields.date];
  const date = rawDate instanceof Date ? rawDate.toISOString() : rawDate;
  const tags = fields.tags ? data?.[fields.tags] ?? [] : [];
  const day = typeof date === 'string' ? date.slice(0, 10) : '';
  if (typeof title !== 'string' || !title.trim() || typeof description !== 'string' || profile.frontMatter.requireDescription && !description.trim()
    || !/^\d{4}-\d{2}-\d{2}$/.test(day) || !Number.isFinite(Date.parse(day)) || new Date(day).toISOString().slice(0, 10) !== day
    || !/^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})| \d{2}:\d{2}:\d{2} [+-]\d{4})?$/.test(date)
    || !Number.isFinite(Date.parse(date)) || !Array.isArray(tags) || tags.some(t => typeof t !== 'string')) throw new Error(`${path}: invalid title, description, date or tags`);
  return { title, description, date: day, sortDate: Date.parse(date), tags, body, path };
}
