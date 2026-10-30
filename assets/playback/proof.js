(() => {
  const expected = window.__proxyyouExpectedId;
  const session = window.__proxyyouExpectedSession;
  const accepted = window.__proxyyouPlaybackSuccess;
  if (accepted && accepted.videoId === expected && accepted.session === session) return accepted;
  const id = new URL(location.href).searchParams.get('v');
  const validPage = /^(www\.|m\.)?youtube\.com$/.test(location.hostname) && id === expected;
  const video = document.querySelector('video');
  if (!validPage || !video) { window.__proxyyouProof = null; return {status: 'waiting'}; }
  const quality = typeof video.getVideoPlaybackQuality === 'function' ? video.getVideoPlaybackQuality() : null;
  const presented = quality ? quality.totalVideoFrames - quality.droppedVideoFrames : video.webkitDecodedFrameCount;
  const requirePresented = window.__proxyyouDecodedProbe && window.__proxyyouRequirePresentedFrames === true;
  let frames = presented;
  // An offscreen WebKit video advances without presenting frames. Acquire an actual
  // decoded VideoFrame and require its media timestamp to advance; never use a timer
  // or count dropped/potential frames as successful background playback.
  if (window.__proxyyouDecodedProbe) {
    if (typeof VideoFrame !== 'function') return {status: 'unsupported'};
    let frame;
    let timestamp;
    try {
      frame = new VideoFrame(video);
      timestamp = frame.timestamp;
      if (!Number.isFinite(timestamp) || frame.codedWidth <= 0 || frame.codedHeight <= 0) {
        return {status: 'waiting'};
      }
    } catch (_) { return {status: 'waiting'}; }
    finally { if (frame) frame.close(); }
    let sampled = window.__proxyyouDecodedSamples;
    if (!sampled || sampled.session !== session || sampled.video !== video || sampled.source !== video.currentSrc) {
      sampled = {session, video, source: video.currentSrc, timestamp, count: 0};
      window.__proxyyouDecodedSamples = sampled;
    } else if (timestamp > sampled.timestamp) {
      sampled.count += 1;
    }
    sampled.timestamp = timestamp;
    frames = sampled.count;
  }
  if (!Number.isFinite(frames)) return {status: 'unsupported'};
  const now = performance.now() / 1000;
  let state = window.__proxyyouProof;
  const source = video.currentSrc;
  if (!state || state.session !== session || state.expected !== expected || state.video !== video || state.source !== source) {
    state = {video, source, session, expected, time: video.currentTime, frames, now, seconds: 0, decoded: 0,
      presentedBase: presented, lastPresented: presented};
    window.__proxyyouProof = state;
    return {status: 'waiting'};
  }
  const delta = video.currentTime - state.time;
  const wall = now - state.now;
  const rendered = frames - state.frames;
  const ad = document.querySelector('.ad-showing, .ad-interrupting');
  const progressing = !ad && !video.paused && !video.ended && !video.seeking && video.readyState >= 2 &&
    video.videoWidth > 0 && video.videoHeight > 0 && video.playbackRate === 1 &&
    delta > 0 && delta < 1.5 && wall > 0 && wall < 1.5 && Math.abs(delta - wall) < 0.65 && rendered > 0;
  if (progressing) { state.seconds += Math.min(delta, wall); state.decoded += rendered; }
  else { state.seconds = 0; state.decoded = 0; state.presentedBase = presented; }
  // Safari may publish presentation counters in bursts. Use fresh decoded frames
  // for continuity; count only the confirmed presentation delta for manual checks.
  const viewed = requirePresented ? Math.max(0, presented - state.presentedBase) : state.decoded;
  const freshPresentation = !requirePresented ||
    (Number.isFinite(presented) && presented > state.lastPresented);
  state.lastPresented = presented;
  state.time = video.currentTime; state.frames = frames; state.now = now;
  const result = {status: state.seconds >= 12 && state.decoded >= 10 && viewed >= 10 && freshPresentation ? 'passed' : 'waiting',
    seconds: state.seconds, frames: Number.isFinite(viewed) ? viewed : 0, videoId: id, session};
  if (result.status === 'passed') window.__proxyyouPlaybackSuccess = Object.freeze(result);
  return result;
})()
