import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { selectDownloads, trustedAsset } from '../../site/downloads.mjs';
const make = (name, overrides = {}) => ({ name, size: 1234, browser_download_url: `https://github.com/Lynatick/proxyyou/releases/download/v4.1.18/${name}`, ...overrides });
const apk = make('ProxyYou-Android-4.1.18.apk');
const mac = make('ProxyYou-macOS-AppleSilicon-4.1.18.zip');
const win = make('ProxyYou-Windows-x64-4.1.18-Setup.exe');
const release = (assets, extra = {}) => ({ tag_name: 'v4.1.18', assets, ...extra });
test('stable platform packages are selected independently', () => {
  const result = selectDownloads([release([apk, mac, win])]);
  assert.deepEqual(Object.keys(result).sort(), ['android', 'macos', 'windows']);
  assert.equal(result.windows.asset.name, win.name);
});
test('draft and prerelease packages are never offered', () => {
  assert.deepEqual(selectDownloads([release([apk], { draft: true }), release([mac], { prerelease: true })]), {});
});
test('missing platform uses previous available stable release', () => {
  const result = selectDownloads([release([apk]), release([make('ProxyYou-macOS-AppleSilicon-4.1.17.zip'), make('ProxyYou-Windows-x64-4.1.17-Setup.exe')], { tag_name: 'v4.1.17' })]);
  assert.equal(result.android.release.tag_name, 'v4.1.18');
  assert.equal(result.macos.release.tag_name, 'v4.1.17');
});
test('foreign repositories, external hosts and insecure protocols are rejected', () => {
  for (const url of ['https://example.com/app.apk', 'http://github.com/Lynatick/proxyyou/releases/download/v4.1.18/file.apk', 'https://github.com/other/proxyyou/releases/download/v4.1.18/file.apk', 'https://github.com.evil.test/Lynatick/proxyyou/releases/download/v4.1.18/file.apk', 'https://user:password@github.com/Lynatick/proxyyou/releases/download/v4.1.18/file.apk']) {
    assert.equal(trustedAsset(make(apk.name, { browser_download_url: url })), false);
  }
});
test('zero byte files, malformed responses and wrong architectures are rejected', () => {
  assert.equal(trustedAsset(make(apk.name, { size: 0 })), false);
  assert.throws(() => selectDownloads({}), TypeError);
  assert.deepEqual(selectDownloads([release([null, make('ProxyYou-Windows-arm64-4.1.18.exe'), make('ProxyYou-macOS-Universal-4.1.18.zip')])]), {});
});
test('empty releases produce no download links', () => assert.deepEqual(selectDownloads([]), {}));

test('file version must match its release tag', () => assert.deepEqual(selectDownloads([release([apk], { tag_name: 'v4.1.17' })]), {}));

test('only Apple Silicon is offered even when older releases include Intel', () => {
 const intel = make('ProxyYou-macOS-Intel-4.1.18.zip');
 const selected = selectDownloads([release([mac, intel])]);
 assert.equal(selected.macos.asset.name, mac.name);
 assert.equal(selected.macosIntel, undefined);
});


test('Windows-only release keeps Silicon and Android from the preceding release', () => {
 const previous = release([apk, mac, win, make('ProxyYou-macOS-Intel-4.1.18.zip')]);
 const nextWin = make('ProxyYou-Windows-x64-4.1.19-Setup.exe');
 const selected = selectDownloads([release([nextWin], { tag_name: 'v4.1.19' }), previous]);
 assert.equal(selected.windows.release.tag_name, 'v4.1.19');
 for (const platform of ['android', 'macos']) assert.equal(selected[platform].release.tag_name, 'v4.1.18');
});

test('the download page contains exactly three supported platform cards', () => {
 const html = readFileSync(new URL('../../site/index.html', import.meta.url), 'utf8');
 assert.equal((html.match(/data-platform=/g) || []).length, 3);
 assert.equal(html.includes('macosIntel'), false);
 assert.equal(html.includes('Intel x86_64'), false);
});

function pageFixture(withLinks = false) {
 const status = {textContent: ''};
 const cards = ['macos','android','windows'].map(platform => {
  const attributes = new Map();
  if (withLinks) attributes.set('href', {macos: mac, android: apk, windows: win}[platform].browser_download_url);
  const button = {textContent: '', getAttribute: key => attributes.get(key) ?? null, setAttribute: (key,value) => attributes.set(key,value), removeAttribute: key => attributes.delete(key)};
  Object.defineProperty(button, 'href', {get: () => attributes.get('href') ?? '', set: value => attributes.set('href',value)});
  const nodes = {'[data-download]':button,'[data-version]':{textContent:'existing version'},'.checksum':{hidden:true},'[data-checksum]':{textContent:''},h3:{textContent:platform}};
  return {dataset:{platform},querySelector:selector=>nodes[selector]};
 });
 return {status,cards,getElementById:()=>status,querySelectorAll:()=>cards};
}
test('downloads load from the same site rather than the GitHub API', async () => {
 const {loadDownloads}=await import('../../site/downloads.mjs');const root=pageFixture();
 await loadDownloads(async url => {assert.equal(url.pathname.endsWith('/site/releases.json'),true);assert.equal(String(url).includes('api.github.com'),false);return {ok:true,json:async()=>[release([apk,mac,win])]};},root);
 for(const card of root.cards)assert.match(card.querySelector('[data-download]').href,/github\.com\/Lynatick\/proxyyou\/releases\/download/);
 assert.equal(root.status.textContent,'Доступные стабильные сборки');
});
for(const [label,fetcher] of Object.entries({offline:async()=>{throw new Error('offline')},http403:async()=>({ok:false,status:403}),invalid:async()=>({ok:true,json:async()=>({error:'invalid'})}),timeout:async()=>{throw new DOMException('timeout','AbortError')}})) {
 test(`existing direct download links survive ${label}`,async()=>{
  const {loadDownloads}=await import('../../site/downloads.mjs');const root=pageFixture(true);const before=root.cards.map(card=>card.querySelector('[data-download]').href);
  await loadDownloads(fetcher,root);
  assert.deepEqual(root.cards.map(card=>card.querySelector('[data-download]').href),before);
  assert.equal(root.status.textContent,'Доступные опубликованные сборки');
 });
}
test('a failed refresh without existing links offers the release page',async()=>{
 const {loadDownloads}=await import('../../site/downloads.mjs');const root=pageFixture();
 await loadDownloads(async()=>{throw new Error('offline')},root);
 for(const card of root.cards)assert.equal(card.querySelector('[data-download]').href,'https://github.com/lynatick/proxyyou/releases');
});
test('static HTML contains direct links and permits same-origin snapshot requests',()=>{
 const html=readFileSync(new URL('../../site/index.html',import.meta.url),'utf8');
 assert.match(html,/connect-src 'self'/);assert.equal((html.match(/data-download href="https:\/\/github.com\//g)||[]).length,3);
});

test('an empty snapshot preserves existing links and a usable availability message',async()=>{
 const {loadDownloads}=await import('../../site/downloads.mjs');const root=pageFixture(true);
 await loadDownloads(async()=>({ok:true,json:async()=>[]}),root);
 assert.equal(root.status.textContent,'Доступные стабильные сборки');
 for(const card of root.cards)assert.ok(card.querySelector('[data-download]').href.includes('/releases/download/'));
});

test('published HTML versions the download module to avoid cached API-dependent scripts',()=>{
 const html=readFileSync(new URL('../../site/index.html',import.meta.url),'utf8');
 assert.match(html,/src="downloads\.mjs\?v=[a-f0-9]{16}"/);
});
