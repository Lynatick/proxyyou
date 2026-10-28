const REPOSITORY = 'lynatick/proxyyou';
const RELEASES_URL = `https://github.com/${REPOSITORY}/releases`;
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
    const response = await fetcher(`https://api.github.com/repos/${REPOSITORY}/releases?per_page=30`, {
      headers: { Accept: 'application/vnd.github+json' }, signal: controller.signal,
    });
    if (!response.ok) throw new Error(`GitHub ${response.status}`);
    const selected = selectDownloads(await response.json());
    for (const card of cards) updateCard(card, selected[card.dataset.platform], false);
    status.textContent = Object.keys(selected).length ? 'Доступные стабильные сборки' : 'Первый релиз готовится. Загрузки появятся здесь после публикации.';
  } catch {
    for (const card of cards) updateCard(card, null, true);
    status.textContent = 'Не удалось получить список загрузок. Откройте страницу релизов GitHub.';
  } finally { clearTimeout(timeout); }
}

if (typeof document !== 'undefined') loadDownloads();
