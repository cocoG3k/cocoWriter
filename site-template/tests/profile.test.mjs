import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, cp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import YAML from 'yaml';
import { stringify as toml } from 'smol-toml';
import { root, build, parseArticle } from '../tools/build.mjs';
import { defaultProfile, validateProfile, imageRepositoryPath } from '../tools/profile.mjs';

test('configured fields, optional description and all three front matter syntaxes', () => {
  const profile = structuredClone(defaultProfile);
  profile.frontMatter.fields = { title: 'heading', description: null, date: 'publishedAt', tags: 'categories' };
  profile.frontMatter.requireDescription = false;
  validateProfile(profile);
  const data = { heading: '記事 " } {', publishedAt: '2026-10-05T12:34:56+09:00', categories: ['日記', 'a,b'], params: { author: 'Writer' } };
  const sources = ['---\n' + YAML.stringify(data) + '---\n', '+++\n' + toml(data) + '+++\n', JSON.stringify(data) + '\n'];
  for (const header of sources) {
    const article = parseArticle(header + '\n本文\n', 'post.md', profile);
    assert.equal(article.title, data.heading); assert.equal(article.description, '');
    assert.equal(article.date, '2026-10-05'); assert.deepEqual(article.tags, data.categories);
    assert.equal(article.body, '\n本文\n');
  }
});

test('Jekyll and Hugo profile combinations validate', () => {
  for (const format of ['yaml', 'toml', 'json']) {
    const profile = structuredClone(defaultProfile);
    profile.articleDirectory = format === 'yaml' ? '_posts' : 'content/posts';
    profile.filenameTemplate = '{date}-ios-{id}.md';
    profile.frontMatter.format = format;
    profile.frontMatter.requireDescription = false;
    profile.frontMatter.extra = { draft: false, layout: 'post' };
    assert.equal(validateProfile(profile), profile);
  }
});

test('invalid paths, templates, duplicated keys and dates fail explicitly', () => {
  for (const directory of ['/content', '../content', 'content//posts', 'content/./posts', 'content\\posts']) {
    const profile = structuredClone(defaultProfile); profile.articleDirectory = directory;
    assert.throws(() => validateProfile(profile));
  }
  for (const mutate of [p => p.filenameTemplate = '{title}.md', p => p.frontMatter.extra.title = 'override',
    p => p.frontMatter.fields.date = 'title', p => p.frontMatter.timeZone = 'unknown/timezone']) {
    const p = structuredClone(defaultProfile); mutate(p); assert.throws(() => validateProfile(p));
  }
  assert.throws(() => parseArticle('---\ntitle: x\ntitle: y\ndescription: z\ndate: 2026-10-05\n---\nbody', 'bad.md'));
  assert.throws(() => parseArticle('{"title":"x","description":"z","date":"2026-02-30"}\nbody', 'bad.md'));
});

test('nested custom storage and separate public paths work at root and project Pages URLs', async () => {
  const project = await mkdtemp(join(tmpdir(), 'pages-profile-'));
  try {
    const profile = structuredClone(defaultProfile);
    profile.articleDirectory = 'docs/blog/content'; profile.imageDirectory = 'private-source/photo-files'; profile.imagePublicPath = '/media/photos';
    profile.frontMatter.format = 'toml'; profile.frontMatter.fields.description = 'summary';
    profile.frontMatter.dateStyle = 'iso8601';
    await cp(join(root, 'public'), join(project, 'public'), { recursive: true });
    await writeFile(join(project, 'blog-profile.json'), JSON.stringify(profile));
    await writeFile(join(project, 'site.config.json'), JSON.stringify({ title: 'Blog', description: 'Summary', language: 'ja', siteURL: 'https://example.github.io', basePath: '/nested/blog/' }));
    const image = '/media/photos/12345678-1234-1234-1234-123456789abc/' + 'a'.repeat(64) + '.jpg';
    const repositoryPath = imageRepositoryPath(image, profile);
    assert.ok(repositoryPath.startsWith('private-source/photo-files/'));
    await mkdir(join(project, profile.articleDirectory, '2026/10'), { recursive: true });
    const body = '\n![写真](' + image + ')\n';
    const source = '+++\n' + toml({ title: '投稿', summary: '説明', date: '2026-10-05T12:34:56+09:00', tags: ['日記'] }) + '+++\n' + body;
    await writeFile(join(project, profile.articleDirectory, '2026/10/post.markdown'), source);
    await writeFile(join(project, profile.articleDirectory, '_index.md'), 'excluded file without header');
    await assert.rejects(build(project, {}), /ENOENT/);
    await mkdir(join(project, repositoryPath, '..'), { recursive: true });
    await writeFile(join(project, repositoryPath), 'fixture photo');
    for (const basePath of ['/nested/blog/', '/']) {
      const result = await build(project, { BASE_PATH: basePath });
      assert.equal(result.articles, 1);
      const page = await readFile(join(project, 'dist/posts/2026/10/post/index.html'), 'utf8');
      assert.ok(page.includes('src="' + basePath + image.slice(1) + '"'));
      assert.match(page, /説明/);
      assert.equal(await readFile(join(project, 'dist', image.slice(1)), 'utf8'), 'fixture photo');
    }
  } finally { await rm(project, { recursive: true, force: true }); }
});

test('absolute image references are copied and rewritten for local and deployed base paths', async () => {
  const project = await mkdtemp(join(tmpdir(), 'pages-absolute-'));
  try {
    const profile = structuredClone(defaultProfile);
    profile.imageDirectory = 'assets/images'; profile.imagePublicPath = '/media/photos'; profile.imageReferenceStyle = 'absolute';
    const website = 'https://example.github.io/journal/';
    const suffix = '12345678-1234-1234-1234-123456789abc/' + 'a'.repeat(64) + '.jpg';
    const reference = website + 'media/photos/' + suffix;
    assert.equal(imageRepositoryPath(reference, profile, website), 'assets/images/' + suffix);
    assert.equal(imageRepositoryPath(reference.replace('example.github.io', 'other.example'), profile, website), null);
    await cp(join(root, 'public'), join(project, 'public'), { recursive: true });
    await mkdir(join(project, profile.articleDirectory), { recursive: true });
    await mkdir(join(project, 'assets/images', suffix, '..'), { recursive: true });
    await writeFile(join(project, 'assets/images', suffix), 'absolute fixture');
    await writeFile(join(project, 'blog-profile.json'), JSON.stringify(profile));
    await writeFile(join(project, 'site.config.json'), JSON.stringify({ title: 'Blog', description: 'Summary', language: 'ja', siteURL: 'https://example.github.io', basePath: '/journal/' }));
    await writeFile(join(project, profile.articleDirectory, 'absolute.md'), '---\ntitle: x\ndescription: y\ndate: 2026-10-05\n---\n![写真](' + reference + ')');
    for (const basePath of ['/journal/', '/']) {
      await build(project, { BASE_PATH: basePath });
      const page = await readFile(join(project, 'dist/posts/absolute/index.html'), 'utf8');
      assert.ok(page.includes('src="' + basePath + 'media/photos/' + suffix + '"'));
      assert.equal(await readFile(join(project, 'dist/media/photos', suffix), 'utf8'), 'absolute fixture');
    }
  } finally { await rm(project, { recursive: true, force: true }); }
});
