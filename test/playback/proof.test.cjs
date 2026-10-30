const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const script = fs.readFileSync('assets/playback/proof.js', 'utf8');
function setup() {
  let now = 0, ad = false;
  const video = {currentTime: 0, currentSrc:'blob:youtube', paused:false, ended:false, seeking:false,
    readyState:4, videoWidth:640, videoHeight:360, playbackRate:1, frames:0,
    getVideoPlaybackQuality(){return {totalVideoFrames:this.frames,droppedVideoFrames:0}}};
  const context = vm.createContext({URL, Number, Math, window:{__proxyyouExpectedId:'jNQXAC9IVRw',__proxyyouExpectedSession:'session-one'},
    location:{href:'https://www.youtube.com/watch?v=jNQXAC9IVRw',hostname:'www.youtube.com'},
    performance:{now:()=>now*1000}, document:{querySelector:s=>s==='video'?video:ad?{}:null}});
  const tick=(seconds=.5,frames=15)=>{now+=.5;video.currentTime+=seconds;video.frames+=frames;return vm.runInContext(script,context)};
  vm.runInContext(script,context);
  return {video, context, tick, setAd:v=>ad=v};
}
test('success requires twelve seconds and progressing decoded frames',()=>{
  const s=setup(); for(let i=0;i<23;i++) assert.equal(s.tick().status,'waiting');
  const result=s.tick(); assert.equal(result.status,'passed'); assert.equal(result.seconds,12); assert.equal(result.frames,360);
});
test('clock advancement without decoded frames cannot pass',()=>{const s=setup();for(let i=0;i<30;i++) assert.notEqual(s.tick(.5,0).status,'passed')});
test('stalled playback cannot pass even when frames increase',()=>{const s=setup();for(let i=0;i<30;i++) assert.notEqual(s.tick(0,15).status,'passed')});
test('seek jumps reset the proof',()=>{const s=setup();for(let i=0;i<9;i++)s.tick();assert.equal(s.tick(20).seconds,0)});
test('paused video resets accumulated progress',()=>{const s=setup();for(let i=0;i<9;i++)s.tick();s.video.paused=true;assert.equal(s.tick().seconds,0)});
test('ads cannot confirm the requested video',()=>{const s=setup();s.setAd(true);for(let i=0;i<30;i++) assert.notEqual(s.tick().status,'passed')});
test('another video cannot inherit the proof',()=>{const s=setup();for(let i=0;i<9;i++)s.tick();s.context.location.href='https://www.youtube.com/watch?v=abcdefghijk';assert.equal(s.tick().status,'waiting')});
test('source changes reset the proof',()=>{const s=setup();for(let i=0;i<9;i++)s.tick();s.video.currentSrc='blob:new';assert.equal(s.tick().status,'waiting');assert.notEqual(s.tick().status,'passed')});
test('absent frame counters are unsupported',()=>{const s=setup();s.video.getVideoPlaybackQuality=undefined;assert.equal(s.tick().status,'unsupported')});
test('dropped frames do not count as displayed frames',()=>{const s=setup();s.video.getVideoPlaybackQuality=function(){return {totalVideoFrames:this.frames,droppedVideoFrames:this.frames}};for(let i=0;i<30;i++)assert.notEqual(s.tick().status,'passed')});

test('success survives pause, end, seek, changed speed, ads and video replacement',()=>{
 const s=setup(); let result;for(let i=0;i<24;i++)result=s.tick();
 assert.equal(result.status,'passed');
 s.video.paused=true;s.video.ended=true;s.video.seeking=true;s.video.playbackRate=2;s.setAd(true);
 s.video.currentSrc='blob:other';s.video.getVideoPlaybackQuality=undefined;
 assert.equal(s.tick(20).status,'passed');
 s.context.document.querySelector=()=>null;
 s.context.location.href='https://www.youtube.com/watch?v=abcdefghijk';
 const preserved=s.tick(0,0);assert.equal(preserved.status,'passed');assert.equal(preserved.seconds,12);
});
test('a new session cannot inherit an earlier successful check',()=>{
 const s=setup();for(let i=0;i<24;i++)s.tick();
 s.context.window.__proxyyouExpectedSession='session-two';
 assert.equal(s.tick().status,'waiting');
});
test('a new requested video cannot inherit a successful check',()=>{
 const s=setup();for(let i=0;i<24;i++)s.tick();
 s.context.window.__proxyyouExpectedId='abcdefghijk';
 s.context.location.href='https://www.youtube.com/watch?v=abcdefghijk';
 assert.equal(s.tick().status,'waiting');
});

function decodedBackground() {
  const s = setup();
  s.context.window.__proxyyouDecodedProbe = true;
  s.context.VideoFrame = class {
    constructor(video) { this.timestamp = video.currentTime * 1000000; this.codedWidth = 640; this.codedHeight = 360; }
    close() { s.closed = (s.closed || 0) + 1; }
  };
  return s;
}
test('background proof requires twelve seconds of real advancing decoded frame timestamps', () => {
  const s = decodedBackground();
  // Offscreen quality counters are intentionally zero; only decoded frame evidence counts.
  let result;
  for (let i = 0; i < 25; i++) result = s.tick(.5, 0);
  assert.equal(result.status, 'passed');
  assert.equal(result.frames, 24);
  assert.equal(result.seconds, 12);
  assert.equal(s.closed, 25);
});
test('a frozen decoded frame cannot confirm background playback even when the video clock advances', () => {
  const s = decodedBackground();
  s.context.VideoFrame = class { constructor() { this.timestamp = 100; this.codedWidth=640; this.codedHeight=360; } close() {} };
  for (let i = 0; i < 30; i++) assert.notEqual(s.tick().status, 'passed');
});
test('missing decoded frame API cannot produce background success', () => {
  const s = decodedBackground(); s.context.VideoFrame = undefined;
  assert.equal(s.tick().status, 'unsupported');
});
test('unavailable or protected decoded frame does not produce background progress', () => {
  const s = decodedBackground();
  s.context.VideoFrame = class { constructor() { throw new Error('unavailable'); } };
  for (let i=0;i<30;i++) assert.equal(s.tick().status, 'waiting');
});
test('zero-sized decoded frames are closed and cannot prove background playback', () => {
  const s = decodedBackground();
  s.context.VideoFrame = class { constructor() { this.timestamp=1; this.codedWidth=0; this.codedHeight=0; } close() { s.closed=(s.closed||0)+1; } };
  for (let i=0;i<30;i++) assert.equal(s.tick().status, 'waiting');
  assert.equal(s.closed,30);
});
test('a new background session cannot inherit a completed decoded proof', () => {
  const s = decodedBackground(); for(let i=0;i<25;i++)s.tick();
  s.context.window.__proxyyouExpectedSession = 'new-server';
  assert.equal(s.tick().status,'waiting');
  assert.equal(s.context.window.__proxyyouDecodedSamples.count,0);
});

test('manual decoded proof handles batched Safari presentation counters without resetting continuous time',()=>{
 const s=decodedBackground(); s.context.window.__proxyyouRequirePresentedFrames=true;
 let result;
 for(let i=1;i<=32;i++) {
  result=s.tick(.5,i%4===0?48:0);
  if(result.status==='passed')break;
 }
 assert.equal(result.status,'passed'); assert.ok(result.seconds>=12);
 assert.equal(result.frames,s.video.frames);
});
test('manual proof cannot pass using decoded timestamps while no displayed frames are confirmed',()=>{
 const s=decodedBackground(); s.context.window.__proxyyouRequirePresentedFrames=true;
 for(let i=0;i<40;i++) { const r=s.tick(.5,0);assert.notEqual(r.status,'passed');assert.equal(r.frames||0,0); }
});
test('manual viewed frame count excludes dropped frames and old frames before the current interval',()=>{
 const s=decodedBackground(); s.context.window.__proxyyouRequirePresentedFrames=true;
 s.video.frames=10000; let dropped=10000;
 s.video.getVideoPlaybackQuality=()=>({totalVideoFrames:s.video.frames,droppedVideoFrames:dropped});
 for(let i=0;i<28;i++) { dropped+=15;assert.notEqual(s.tick(.5,15).status,'passed'); }
 const before=s.video.frames; s.video.paused=true;s.tick(.5,0);s.video.paused=false;
 let result;for(let i=0;i<26;i++){result=s.tick();if(result.status==='passed')break;}
 assert.equal(result.status,'passed');assert.equal(result.frames,s.video.frames-before);
 assert.ok(result.frames<1000);
});
