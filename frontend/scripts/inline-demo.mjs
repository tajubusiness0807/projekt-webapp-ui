// Fasst die Browser-Demo (dist-demo) zu einer einzigen HTML-Datei zusammen:
// dist-demo/allwheel-demo.html – ohne Server direkt im Browser lauffähig, keine externen Ressourcen.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const dist = join(dirname(fileURLToPath(import.meta.url)), '..', 'dist-demo');
let html = readFileSync(join(dist, 'index.html'), 'utf8');

html = html.replace(/<script type="module" crossorigin src="\.\/(assets\/[^"]+\.js)"><\/script>/, (_, file) => {
  const js = readFileSync(join(dist, file), 'utf8').replace(/<\/script/gi, '<\\/script');
  return `<script type="module">${js}</script>`;
});
html = html.replace(/<link rel="stylesheet" crossorigin href="\.\/(assets\/[^"]+\.css)">/, (_, file) => {
  const css = readFileSync(join(dist, file), 'utf8');
  if (/url\(\.\/|url\(\/assets/.test(css)) throw new Error('CSS verweist noch auf externe Dateien');
  return `<style>${css}</style>`;
});
html = html.replace(/\s*<link rel="(icon|manifest)"[^>]*>/g, '');
if (/src="\.\/assets|href="\.\/assets/.test(html)) throw new Error('Nicht alle Ressourcen wurden eingebettet');
writeFileSync(join(dist, 'allwheel-demo.html'), html);
console.log(`Browser-Demo: ${join(dist, 'allwheel-demo.html')} (${Math.round(html.length / 1024)} KB)`);
