(() => {
  let userStarted = false;
  const automatic = () => window.__proxyyouAutomaticPlayback === true;
  window.__proxyyouRequirePresentedFrames = !automatic();
  const silence = video => {
    video.defaultMuted = true;
    if (!video.muted) video.muted = true;
    if (!automatic()) { video.autoplay = false; video.removeAttribute('autoplay'); }
  };
  const videos = () => document.querySelectorAll('video, audio');
  const prepare = () => videos().forEach(silence);
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function (...args) {
    silence(this);
    if (!automatic() && !userStarted) {
      return Promise.reject(new DOMException('Start playback with the Play button', 'NotAllowedError'));
    }
    return play.apply(this, args);
  };
  document.addEventListener('click', event => {
    if (event.isTrusted && event.target?.closest?.('video, #movie_player, .html5-video-player, [data-proxyyou-play]')) {
      userStarted = true;
    }
  }, true);
  document.addEventListener('keydown', event => {
    if (event.isTrusted && [' ', 'Enter', 'k', 'K'].includes(event.key)) userStarted = true;
  }, true);
  document.addEventListener('play', event => {
    silence(event.target);
    if (!automatic() && !userStarted) event.target.pause();
  }, true);
  document.addEventListener('volumechange', event => silence(event.target), true);
  new MutationObserver(prepare).observe(document, {childList: true, subtree: true});
  document.addEventListener('DOMContentLoaded', prepare, {once: true});
  window.__proxyyouRequireManualStart = () => {
    window.__proxyyouAutomaticPlayback = false;
    window.__proxyyouRequirePresentedFrames = true;
    userStarted = false;
    videos().forEach(video => { silence(video); video.pause(); });
  };
  prepare();
})();
