import { readFile, readdir, mkdir, writeFile, cp, rm } from 'node:fs/promises';
import { resolve, dirname, relative, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import MarkdownIt from 'markdown-it';
import { defaultProfile, validateProfile, imageRepositoryPath, parseContent } from './profile.mjs';

export const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const escape = (value) => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');

export function normalizeBasePath(value) {
  const parts = String(value).split('/').filter(Boolean);
  if (parts.some((p) => p === '.' || p === '..' || /[?#\\]/.test(p))) throw new Error('Invalid base path');
  return parts.length ? '/' + parts.join('/') + '/' : '/';
}

export function settings(config, env = process.env) {
  const basePath = normalizeBasePath(env.BASE_PATH ?? config.basePath ?? '/');
  const url = new URL(env.SITE_URL ?? config.siteURL);
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash || url.pathname !== '/') {
    throw new Error('siteURL must be an HTTPS origin. Set the repository path separately in basePath.');
  }
  if (!config.title || !config.description || !/^[a-zA-Z-]+$/.test(config.language)) throw new Error('Invalid site settings');
  return { ...config, basePath, origin: url.origin };
}

export const parseArticle = parseContent;

export function renderer(basePath, profile = defaultProfile, websiteURLs = []) {
  const md = new MarkdownIt({ html: false, linkify: false, breaks: false });
  // The app's only raw HTML output is a Spotify player. Keep other HTML escaped.
  md.block.ruler.before('paragraph', 'spotify', (state, start, end, silent) => {
    const line = state.src.slice(state.bMarks[start] + state.tShift[start], state.eMarks[start]);
    const match = line.match(/^\s*<iframe\b[^>]*\bsrc\s*=\s*["'](https:\/\/open\.spotify\.com\/embed\/(track|album)\/([A-Za-z0-9]{22})(?:\?[^"']*)?)["'][^>]*>\s*<\/iframe>\s*$/i);
    if (!match) return false;
    if (!silent) {
      const token = state.push('spotify', '', 0);
      token.content = `https://open.spotify.com/embed/${match[2].toLowerCase()}/${match[3]}`;
      state.line = start + 1;
    }
    return true;
  });
  md.renderer.rules.spotify = (tokens, index) => `<iframe title="Spotify" src="${escape(tokens[index].content)}" width="100%" height="352" style="border-radius:12px" frameborder="0" loading="lazy" allow="encrypted-media"></iframe>\n`;
  const original = md.renderer.rules.image;
  md.renderer.rules.image = (tokens, index, options, env, self) => {
    const token = tokens[index];
    const src = token.attrGet('src') ?? '';
    if (imageRepositoryPath(src, profile, websiteURLs)) {
      env.images?.add(src);
      const repositoryPath = imageRepositoryPath(src, profile, websiteURLs);
      const suffix = repositoryPath.slice(profile.imageDirectory ? profile.imageDirectory.length + 1 : 0);
      token.attrSet('src', basePath + (profile.imagePublicPath === '/' ? '' : profile.imagePublicPath.slice(1) + '/') + suffix);
    } else if (!/^https:\/\//i.test(src)) {
      return escape(token.content);
    }
    token.attrSet('loading', 'lazy');
    return original(tokens, index, options, env, self);
  };
  return md;
}

async function files(directory, profile) {
  const output = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (['node_modules', 'dist', '.git', '.github'].includes(entry.name)) continue;
    if (entry.isSymbolicLink()) throw new Error('Symlinks are not supported: ' + entry.name);
    if (entry.isDirectory()) output.push(...await files(path, profile));
    else if (profile.articleExtensions.includes(entry.name.split('.').at(-1)) && !profile.excludedArticleNames.includes(entry.name)) output.push(path);
  }
  return output.sort();
}

export function layout(config, { title, description, body, route }) {
  const canonical = config.origin + config.basePath + route;
  return `<!doctype html><html lang="${escape(config.language)}"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="${escape(description)}">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'self' 'unsafe-inline'; img-src https: data:; frame-src https://open.spotify.com; script-src 'none'; base-uri 'none'; form-action 'none'">
<title>${escape(title)} | ${escape(config.title)}</title><link rel="canonical" href="${escape(canonical)}">
<link rel="stylesheet" href="${escape(config.basePath)}styles.css"></head><body><div class="page">
<header class="site-header"><a class="site-name" href="${escape(config.basePath)}">${escape(config.title)}</a><p class="tagline">${escape(config.description)}</p></header>
<nav class="site-nav" aria-label="メインナビゲーション"><a href="${escape(config.basePath)}">記事一覧</a></nav>
<main class="reading-layout">${body}</main><footer class="site-footer">${escape(config.title)}</footer></div></body></html>`;
}

export async function build(projectRoot = root, env = process.env) {
  const rawConfig = JSON.parse(await readFile(join(projectRoot, 'site.config.json'), 'utf8'));
  const config = settings(rawConfig, env);
  const sourceConfig = settings(rawConfig, {});
  const websiteURLs = [config.origin + config.basePath, sourceConfig.origin + sourceConfig.basePath];
  const profile = validateProfile(JSON.parse(await readFile(join(projectRoot, 'blog-profile.json'), 'utf8')));
  const directory = join(projectRoot, profile.articleDirectory);
  const articles = [];
  const md = renderer(config.basePath, profile, websiteURLs);
  for (const path of await files(directory, profile)) {
    const article = parseArticle(await readFile(path, 'utf8'), relative(directory, path), profile);
    const slug = article.path.replace(/\.(md|markdown)$/, '').split('/').map(encodeURIComponent).join('/');
    article.route = 'posts/' + slug + '/';
    article.output = join('posts', article.path.replace(/\.(md|markdown)$/, ''), 'index.html');
    const images = new Set();
    article.html = md.render(article.body, { images });
    // A missing attachment must stop deployment instead of publishing a broken article.
    for (const image of images) {
      await readFile(join(projectRoot, imageRepositoryPath(image, profile, websiteURLs)));
    }
    article.images = images;
    articles.push(article);
  }
  articles.sort((a, b) => b.sortDate - a.sortDate || a.path.localeCompare(b.path));
  const dist = join(projectRoot, 'dist');
  await rm(dist, { recursive: true, force: true });
  await mkdir(dist, { recursive: true });
  await cp(join(projectRoot, 'public'), dist, { recursive: true });
  for (const article of articles) {
    for (const image of article.images) {
      const output = join(dist, profile.imagePublicPath.slice(1), imageRepositoryPath(image, profile, websiteURLs).slice(profile.imageDirectory ? profile.imageDirectory.length + 1 : 0));
      await mkdir(dirname(output), { recursive: true });
      await cp(join(projectRoot, imageRepositoryPath(image, profile, websiteURLs)), output);
    }
    const body = `<header class="article-header"><div class="article-meta"><time class="date" datetime="${article.date}">${article.date.replaceAll('-', '.')}</time><div class="tag-list">${article.tags.map((t) => `<span>${escape(t)}</span>`).join('')}</div></div><h1>${escape(article.title)}</h1><p class="description">${escape(article.description)}</p></header><article class="prose">${article.html}</article>`;
    const output = join(dist, article.output);
    await mkdir(dirname(output), { recursive: true });
    await writeFile(output, layout(config, { ...article, body }));
  }
  const list = articles.map((a) => `<li class="article-card"><time datetime="${a.date}">${a.date}</time><h2><a href="${escape(config.basePath + a.route)}">${escape(a.title)}</a></h2><p>${escape(a.description)}</p></li>`).join('');
  await writeFile(join(dist, 'index.html'), layout(config, { title: '記事一覧', description: config.description, route: '', body: `<header class="article-header"><h1>記事一覧</h1></header><ul class="article-list">${list || '<li>まだ記事がありません。</li>'}</ul>` }));
  await writeFile(join(dist, '404.html'), layout(config, { title: 'ページが見つかりません', description: config.description, route: '404.html', body: `<h1>ページが見つかりません</h1><p><a href="${escape(config.basePath)}">記事一覧へ戻る</a></p>` }));
  await writeFile(join(dist, '.nojekyll'), '');
  return { articles: articles.length, basePath: config.basePath, dist };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = await build();
  console.log(`Built ${result.articles} articles at ${result.basePath}`);
}
