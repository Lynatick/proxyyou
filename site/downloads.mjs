const RELEASES_URL = 'https://github.com/lynatick/proxyyou/releases';
const PATTERNS = {
  macos: /^ProxyYou-macOS-AppleSilicon-\d+\.\d+\.\d+\.zip$/i,
  android: /^ProxyYou-Android-\d+\.\d+\.\d+\.apk$/i,
  windows: /^ProxyYou-Windows-x64-\d+\.\d+\.\d+-Setup\.exe$/i,
};

export function trustedAsset(asset) {
  if (!asset || typeof asset.browser_download_url !== 'string' || !Number.isFinite(asset.size) || asset.size <= 0) return false;
  try {
    const url = new URL(asset.browser_download_url);
    return url.protocol === 'https:' && url.hostname === 'github.com' && !url.username && !url.password &&
      url.pathname.toLowerCase().startsWith('/lynatick/proxyyou/releases/download/');
  } catch { return false; }
}

export function selectDownloads(releases) {
  if (!Array.isArray(releases)) throw new TypeError('Invalid GitHub release response');
  const selected = {};
  for (const release of releases) {
    if (!release || release.draft || release.prerelease || !Array.isArray(release.assets)) continue;
    for (const [platform, pattern] of Object.entries(PATTERNS)) {
      if (selected[platform]) continue;
      const releaseVersion = String(release.tag_name ?? '').replace(/^v/, '');
      const asset = release.assets.find(candidate => {
        const version = candidate?.name?.match(/-(\d+\.\d+\.\d+)(?:-Setup)?\./)?.[1];
        return pattern.test(candidate?.name ?? '') && version === releaseVersion && trustedAsset(candidate);
      });
      if (asset) selected[platform] = { asset, release };
    }
  }
  return selected;
}

function hasDownload(card) {
  const href = card.querySelector('[data-download]').getAttribute('href');
  return !!href && trustedAsset({ browser_download_url: href, size: 1 });
}

function updateCard(card, match, failed) {
  const button = card.querySelector('[data-download]');
  const version = card.querySelector('[data-version]');
  button.removeAttribute('href');
  button.setAttribute('aria-disabled', 'true');
  card.querySelector('.checksum').hidden = true;
  if (!match) {
    button.textContent = failed ? 'Открыть релизы ↗' : 'Релиз готовится';
    version.textContent = failed ? 'Версию не удалось проверить' : 'Сборка пока не опубликована';
    if (failed) { button.href = RELEASES_URL; button.removeAttribute('aria-disabled'); }
    return;
  }
  const { asset, release } = match;
  button.href = asset.browser_download_url;
  button.textContent = 'Скачать ↓';
  button.setAttribute('aria-label', `Скачать ${card.querySelector('h3').textContent}: ${asset.name}`);
  button.removeAttribute('aria-disabled');
  const mb = (asset.size / 1024 / 1024).toLocaleString('ru-RU', { maximumFractionDigits: 1 });
  version.textContent = `${release.tag_name} · ${mb} МБ`;
  if (/^sha256:[a-f0-9]{64}$/i.test(asset.digest ?? '')) {
    card.querySelector('.checksum').hidden = false;
    card.querySelector('[data-checksum]').textContent = asset.digest.slice(7);
  }
}

export async function loadDownloads(fetcher = fetch, root = document) {
  const status = root.getElementById('release-status');
  const cards = root.querySelectorAll('[data-platform]');
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12000);
  try {
    const response = await fetcher(new URL('releases.json', import.meta.url), { signal: controller.signal });
    if (!response.ok) throw new Error(`Release snapshot ${response.status}`);
    const selected = selectDownloads(await response.json());
    for (const card of cards) {
      if (selected[card.dataset.platform] || !hasDownload(card)) updateCard(card, selected[card.dataset.platform], false);
    }
    status.textContent = [...cards].some(hasDownload) ? 'Доступные стабильные сборки' : 'Первый релиз готовится. Загрузки появятся здесь после публикации.';
  } catch {
    for (const card of cards) if (!hasDownload(card)) updateCard(card, null, true);
    status.textContent = [...cards].some(hasDownload)
      ? 'Доступные опубликованные сборки'
      : 'Не удалось получить список загрузок. Откройте страницу релизов GitHub.';
  } finally { clearTimeout(timeout); }
}

if (typeof document !== 'undefined') loadDownloads();
