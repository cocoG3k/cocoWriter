import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, cp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { root, build, renderer, settings, parseArticle } from '../tools/build.mjs';

test('root, project Pages and custom-domain settings', () => {
  const config = { title: 'Journal', description: 'Description', language: 'ja', siteURL: 'https://example.github.io', basePath: '/journal/' };
  assert.equal(settings(config, {}).basePath, '/journal/');
  assert.equal(settings(config, { BASE_PATH: '' }).basePath, '/');
  assert.equal(settings(config, { BASE_PATH: '/', SITE_URL: 'https://blog.example.org' }).origin, 'https://blog.example.org');
  assert.throws(() => settings(config, { BASE_PATH: '/../bad/' }));
});

test('safe Spotify embeds and escaping for raw HTML', () => {
  const md = renderer('/journal/');
  assert.match(md.render('<iframe onload="evil()" src="https://open.spotify.com/embed/album/0123456789ABCDEFGHIJKL?utm_source=generator"></iframe>'), /<iframe title="Spotify"/);
  assert.doesNotMatch(md.render('<iframe onload="evil()" src="https://open.spotify.com/embed/album/0123456789ABCDEFGHIJKL"></iframe>'), /onload/);
  for (const html of ['<script>alert(1)</script>', '<iframe src="https://evil.example/"></iframe>']) {
    assert.doesNotMatch(md.render(html), /<(script|iframe)/);
  }
  assert.doesNotMatch(md.render('[bad](javascript:alert%281%29)'), /href="javascript:/);
});

test('project Pages routes, app front matter, photos and missing-attachment failure', async () => {
  const project = await mkdtemp(join(tmpdir(), 'cocowriter-'));
  try {
    await cp(join(root, 'blog-profile.json'), join(project, 'blog-profile.json'));
    await cp(join(root, 'public'), join(project, 'public'), { recursive: true });
    await mkdir(join(project, 'src/content/diary'), { recursive: true });
    await writeFile(join(project, 'site.config.json'), JSON.stringify({ title: '<Journal>', description: 'Description', language: 'ja', siteURL: 'https://example.github.io', basePath: '/journal/' }));
    const image = '/images/diary/12345678-1234-1234-1234-123456789abc/' + 'a'.repeat(64) + '.jpg';
    const article = '---\ntitle: "A <title>"\ndescription: "Description"\ndate: 2026-10-05\ntags: ["日記"]\n---\n\n![Photo](' + image + ')\n';
    const file = join(project, 'src/content/diary/photo #1.md');
    await writeFile(file, article);
    await assert.rejects(build(project, {}), /ENOENT/);
    await mkdir(join(project, 'public', image.slice(1), '..'), { recursive: true });
    await writeFile(join(project, 'public', image.slice(1)), 'fixture');
    const result = await build(project, {});
    assert.equal(result.articles, 1);
    const index = await readFile(join(project, 'dist/index.html'), 'utf8');
    assert.match(index, /href="\/journal\/posts\/photo%20%231\/"/);
    const page = await readFile(join(project, 'dist/posts/photo #1/index.html'), 'utf8');
    assert.match(page, /A &lt;title&gt;/);
    assert.ok(page.includes('src="/journal' + image + '"'));
    assert.match(page, /href="https:\/\/example.github.io\/journal\/posts\/photo%20%231\/"/);
    await build(project, { BASE_PATH: '/', SITE_URL: 'https://blog.example.org' });
    const custom = await readFile(join(project, 'dist/posts/photo #1/index.html'), 'utf8');
    assert.ok(custom.includes('src="' + image + '"'));
  } finally { await rm(project, { recursive: true, force: true }); }
});

test('invalid content fails clearly', () => {
  assert.throws(() => parseArticle('No header', 'bad.md'));
  assert.throws(() => parseArticle('---\ntitle: x\ndescription: x\ndate: 2026-02-30\n---\nbody', 'bad.md'));
});
