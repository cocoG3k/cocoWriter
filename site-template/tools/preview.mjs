import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { join, resolve, sep } from 'node:path';
import { build } from './build.mjs';

const { dist, basePath } = await build();
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.jpg': 'image/jpeg', '.png': 'image/png' };
http.createServer(async (request, response) => {
  try {
    const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    if (!pathname.startsWith(basePath)) {
      response.writeHead(302, { Location: basePath }); response.end(); return;
    }
    let path = resolve(dist, pathname.slice(basePath.length));
    if (path !== dist && !path.startsWith(dist + sep)) throw new Error('Invalid path');
    if ((await stat(path)).isDirectory()) path = join(path, 'index.html');
    const extension = path.slice(path.lastIndexOf('.'));
    response.writeHead(200, { 'Content-Type': types[extension] ?? 'application/octet-stream' });
    response.end(await readFile(path));
  } catch { response.writeHead(404); response.end('Not found'); }
}).listen(4321, '127.0.0.1', () => console.log(`Preview: http://127.0.0.1:4321${basePath}`));
