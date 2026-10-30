const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync('assets/playback/controls.js', 'utf8');
function fixture(automatic) {
  const events = new Map();
  class Media {
    constructor() { this.muted=false; this.defaultMuted=false; this.autoplay=true; this.paused=true; this.plays=0; }
    play() { this.paused=false; this.plays++; return Promise.resolve(); }
    pause() { this.paused=true; }
    removeAttribute(name) { if (name==='autoplay') this.autoplay=false; }
  }
  const video = new Media();
  const elements = [video];
  let mutate;
  const context=vm.createContext({window:{__proxyyouAutomaticPlayback:automatic}, HTMLMediaElement: Media,
    Promise, DOMException,
    document:{querySelectorAll:()=>elements, addEventListener:(name,fn)=>events.set(name,fn)},
    MutationObserver: class { constructor(fn) { mutate=fn; } observe() {} }});
  vm.runInContext(source, context);
  return {video,elements,Media,events,context,mutate:()=>mutate()};
}
test('manual opening is muted and refuses script/autoplay before a user gesture', async()=>{
 const f=fixture(false); assert.equal(f.video.muted,true); assert.equal(f.video.defaultMuted,true);
 assert.equal(f.video.autoplay,false); await assert.rejects(f.video.play(),{name:'NotAllowedError'});
 assert.equal(f.video.plays,0); assert.equal(f.video.paused,true);
});
test('synthetic clicks cannot start manual playback', async()=>{
 const f=fixture(false); f.events.get('click')({isTrusted:false,target:{closest:()=>true}});
 await assert.rejects(f.video.play(),{name:'NotAllowedError'});
});
test('a trusted Play interaction starts a muted manual video', async()=>{
 const f=fixture(false); f.events.get('click')({isTrusted:true,target:{closest:()=>true}});
 await f.video.play(); assert.equal(f.video.plays,1); assert.equal(f.video.muted,true);
});
test('automatic checking plays silently without a user gesture', async()=>{
 const f=fixture(true); await f.video.play(); assert.equal(f.video.paused,false); assert.equal(f.video.muted,true);
});
test('promotion pauses a background video and waits for manual Play while staying muted', async()=>{
 const f=fixture(true); await f.video.play();
 f.context.window.__proxyyouRequireManualStart(); assert.equal(f.video.paused,true);
 assert.equal(f.video.muted,true); await assert.rejects(f.video.play(),{name:'NotAllowedError'});
 f.events.get('keydown')({isTrusted:true,key:' '}); await f.video.play(); assert.equal(f.video.muted,true);
});
test('dynamically inserted media is silenced and manual autoplay removed',()=>{
 const f=fixture(false); const next=new f.Media(); f.elements.push(next); f.mutate();
 assert.equal(next.muted,true); assert.equal(next.autoplay,false);
});
test('volume changes are remuted without restarting playback',()=>{
 const f=fixture(true); f.video.muted=false; f.events.get('volumechange')({target:f.video});
 assert.equal(f.video.muted,true); assert.equal(f.video.plays,0);
});
test('native autoplay events before manual approval are paused',()=>{
 const f=fixture(false); f.video.paused=false; f.events.get('play')({target:f.video});
 assert.equal(f.video.paused,true); assert.equal(f.video.muted,true);
});
