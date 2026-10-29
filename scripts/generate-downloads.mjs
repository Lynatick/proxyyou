import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { selectDownloads, trustedAsset } from '../site/downloads.mjs';

export function releaseSnapshot(releases) {
  if (!Array.isArray(releases)) throw new TypeError('Invalid release response');
  return releases.filter(release => release && !release.draft && !release.prerelease && Array.isArray(release.assets))
    .map(release => ({ tag_name: release.tag_name, assets: release.assets.filter(asset => trustedAsset(asset) &&
      /^ProxyYou-(macOS-AppleSilicon-\d+\.\d+\.\d+\.zip|Android-\d+\.\d+\.\d+\.apk|Windows-x64-\d+\.\d+\.\d+-Setup\.exe)$/.test(asset.name))
      .map(({ name, size, browser_download_url, digest }) => ({ name, size, browser_download_url, digest })) }));
}
const escape = value => String(value).replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
export function renderDownloads(html, releases) {
  const selected = selectDownloads(releases);
  for (const platform of ['macos', 'android', 'windows']) {
    const match = selected[platform];
    if (!match) throw new Error(`No stable package for ${platform}; keep the previous site deployment`);
    const { asset, release } = match;
    let rendered = false;
    html = html.replace(new RegExp(`(<article\\b[^>]*data-platform="${platform}"[^>]*>)([\\s\\S]*?)(</article>)`), (_, open, body, close) => {
      rendered = true;
      const version = `${release.tag_name} · ${(asset.size / 1024 / 1024).toLocaleString('ru-RU', {maximumFractionDigits: 1})} МБ`;
      body = body.replace(/(<div class="version" data-version>)[\s\S]*?(<\/div>)/, `$1${escape(version)}$2`)
        .replace(/<a class="button download"[^>]*>[\s\S]*?<\/a>/, `<a class="button download" data-download href="${escape(asset.browser_download_url)}">Скачать ↓</a>`);
      if (/^sha256:[a-f0-9]{64}$/i.test(asset.digest ?? '')) body = body.replace('class="checksum" hidden', 'class="checksum"')
        .replace(/(<code data-checksum>)[\s\S]*?(<\/code>)/, `$1${asset.digest.slice(7)}$2`);
      else body = body.replace(/class="checksum"(?: hidden)?/, 'class="checksum" hidden')
        .replace(/(<code data-checksum>)[\s\S]*?(<\/code>)/, '$1$2');
      return open + body + close;
    });
    if (!rendered) throw new Error(`Missing download card: ${platform}`);
  }
  return html.replace(/(<p class="release-status"[^>]*>)[\s\S]*?(<\/p>)/, '$1Доступные стабильные сборки$2');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const input = process.argv.indexOf('--input');
  let releases;
  if (input >= 0) releases = JSON.parse(await readFile(process.argv[input + 1], 'utf8'));
  else {
    const headers = {Accept: 'application/vnd.github+json'};
    if (process.env.GH_TOKEN) headers.Authorization = `Bearer ${process.env.GH_TOKEN}`;
    const response = await fetch('https://api.github.com/repos/lynatick/proxyyou/releases?per_page=30', {headers, signal: AbortSignal.timeout(30000)});
    if (!response.ok) throw new Error(`Release snapshot request failed: HTTP ${response.status}`);
    releases = await response.json();
  }
  const snapshot = releaseSnapshot(releases);
  const contentVersion = createHash('sha256').update(await readFile(new URL('../site/downloads.mjs', import.meta.url))).update(JSON.stringify(snapshot)).digest('hex').slice(0, 16);
  const html = renderDownloads(await readFile(new URL('../site/index.html', import.meta.url), 'utf8'), snapshot).replace(/src="downloads\.mjs(?:\?[^"]*)?"/, `src="downloads.mjs?v=${contentVersion}"`);
  await writeFile(new URL('../site/releases.json', import.meta.url), JSON.stringify(snapshot) + '\n');
  await writeFile(new URL('../site/index.html', import.meta.url), html);
  console.log('Generated same-origin release snapshot and three ready-to-use HTML download links');
}
