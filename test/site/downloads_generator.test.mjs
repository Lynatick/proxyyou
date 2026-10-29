import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {releaseSnapshot,renderDownloads} from '../../scripts/generate-downloads.mjs';
const version='4.1.33';const asset=name=>({name,size:1000,browser_download_url:`https://github.com/lynatick/proxyyou/releases/download/v${version}/${name}`,digest:'sha256:'+'a'.repeat(64),irrelevant:'private metadata'});
const releases=[{tag_name:'v'+version,body:'omit',assets:['ProxyYou-Android-4.1.33.apk','ProxyYou-macOS-AppleSilicon-4.1.33.zip','ProxyYou-Windows-x64-4.1.33-Setup.exe','ProxyYou-source.zip'].map(asset)}];
test('snapshot is compact, stable and excludes source and irrelevant metadata',()=>{
 const snapshot=releaseSnapshot(releases);assert.equal(snapshot[0].assets.length,3);assert.equal('body' in snapshot[0],false);assert.equal('irrelevant' in snapshot[0].assets[0],false);
 assert.deepEqual(releaseSnapshot([{...releases[0],draft:true},{...releases[0],prerelease:true}]),[]);
});
test('foreign links cannot enter the snapshot',()=>{
 const changed=structuredClone(releases);changed[0].assets[0].browser_download_url='https://evil.example/app.apk';assert.equal(releaseSnapshot(changed)[0].assets.length,2);
});
test('render embeds all three versions, direct download links and checksums, and is idempotent',()=>{
 const html=readFileSync(new URL('../../site/index.html',import.meta.url),'utf8');const rendered=renderDownloads(html,releases);
 assert.equal((rendered.match(/data-download href="https:\/\/github.com\//g)||[]).length,3);assert.equal((rendered.match(/v4\.1\.33 ·/g)||[]).length,3);assert.equal((rendered.match(/a{64}/g)||[]).length,3);
 assert.equal(renderDownloads(rendered,releases),rendered);
});
test('an incomplete release history cannot overwrite a working site deployment',()=>{
 assert.throws(()=>renderDownloads('<html></html>',[]),/No stable package/);
});

test('missing digest hides and clears a previous checksum',()=>{
 const html=readFileSync(new URL('../../site/index.html',import.meta.url),'utf8');const changed=structuredClone(releases);changed[0].assets.forEach(a=>delete a.digest);
 const rendered=renderDownloads(html,changed);assert.equal((rendered.match(/class="checksum" hidden/g)||[]).length,3);assert.equal((rendered.match(/<code data-checksum><\/code>/g)||[]).length,3);
});
test('missing platform cards abort generation instead of deploying broken HTML',()=>{
 assert.throws(()=>renderDownloads('<html></html>',releases),/Missing download card/);
});
