/*
 * Viewer ad-skip scriptlet.
 * Injected at document end into the main frame and every subframe.
 * Original implementation: it only acts while an ad UI is on screen.
 */
(function () {
  "use strict";

  if (window.__viewerAdSkip) {
    return;
  }
  window.__viewerAdSkip = true;

  var SKIP = [
    ".ytp-ad-skip-button",
    ".ytp-ad-skip-button-modern",
    ".ytp-skip-ad-button",
    ".ytp-ad-skip-button-container button",
    "button.ytp-ad-skip-button-slot"
  ];

  var CLOSE = [
    ".ytp-ad-overlay-close-button",
    ".ytp-ad-overlay-close-container button"
  ];

  var HIDE = [
    ".ytp-ad-overlay-container",
    ".ytp-ad-overlay-slot",
    ".ytp-ad-image-overlay",
    ".ytp-ad-text-overlay",
    ".video-ads",
    "#player-ads",
    "ytd-display-ad-renderer",
    "ytd-ad-slot-renderer",
    "ytd-banner-promo-renderer",
    "ytd-in-feed-ad-layout-renderer",
    "ytd-companion-slot-renderer",
    "ytd-action-companion-ad-renderer",
    "ytd-promoted-sparkles-web-renderer",
    "ytd-promoted-video-renderer"
  ];

  var touched = [];

  function clickElement(element) {
    if (element && typeof element.click === "function") {
      element.click();
    }
  }

  function clickAll(selectors, root) {
    var scope = root || document;
    for (var i = 0; i < selectors.length; i++) {
      var nodes;
      try {
        nodes = scope.querySelectorAll(selectors[i]);
      } catch (e) {
        continue;
      }
      for (var j = 0; j < nodes.length; j++) {
        clickElement(nodes[j]);
      }
    }
  }

  function clickLabeledSkip(player) {
    var nodes;
    try {
      nodes = player.querySelectorAll("button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern");
    } catch (e) {
      return;
    }
    for (var i = 0; i < nodes.length; i++) {
      var text = (nodes[i].textContent || "").replace(/\s+/g, " ").trim().toLowerCase();
      if (text.indexOf("skip") !== -1 || text.indexOf("スキップ") !== -1) {
        clickElement(nodes[i]);
      }
    }
  }

  function remember(video) {
    if (!video.__viewerSaved) {
      video.__viewerSaved = {
        muted: video.muted,
        rate: video.playbackRate || 1
      };
    }
    if (touched.indexOf(video) === -1) {
      touched.push(video);
    }
  }

  function fastForward(player) {
    var video = player.querySelector("video");
    if (!video) {
      return;
    }
    try {
      remember(video);
      video.muted = true;
      if (
        isFinite(video.duration) &&
        video.duration > 0.4 &&
        video.duration < 180 &&
        video.currentTime < video.duration - 0.2
      ) {
        video.currentTime = video.duration;
      }
      video.playbackRate = 16;
    } catch (e) {}
  }

  function restoreFinished() {
    for (var i = touched.length - 1; i >= 0; i--) {
      var video = touched[i];
      if (!video || !video.isConnected) {
        touched.splice(i, 1);
        continue;
      }
      var player = video.closest ? video.closest(".html5-video-player") : null;
      if (player && player.classList.contains("ad-showing")) {
        continue;
      }
      try {
        if (video.__viewerSaved) {
          video.muted = video.__viewerSaved.muted;
          video.playbackRate = video.__viewerSaved.rate || 1;
          video.__viewerSaved = null;
        }
      } catch (e) {}
      touched.splice(i, 1);
    }
  }

  function hideOverlays() {
    for (var i = 0; i < HIDE.length; i++) {
      var nodes;
      try {
        nodes = document.querySelectorAll(HIDE[i]);
      } catch (e) {
        continue;
      }
      for (var j = 0; j < nodes.length; j++) {
        nodes[j].style.setProperty("display", "none", "important");
      }
    }
  }

  function tick() {
    var player = document.querySelector(".html5-video-player.ad-showing");
    if (player) {
      clickAll(SKIP, player);
      clickAll(CLOSE, player);
      clickLabeledSkip(player);
      fastForward(player);
    }
    clickAll(CLOSE, document);
    hideOverlays();
    restoreFinished();
  }

  var scheduled = false;
  function schedule() {
    if (scheduled) {
      return;
    }
    scheduled = true;
    requestAnimationFrame(function () {
      scheduled = false;
      try {
        tick();
      } catch (e) {}
    });
  }

  try {
    tick();
  } catch (e) {}

  try {
    var root = document.documentElement || document;
    new MutationObserver(schedule).observe(root, { childList: true, subtree: true });
  } catch (e) {}

  setInterval(function () {
    try {
      tick();
    } catch (e) {}
  }, 500);
})();
