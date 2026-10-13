// Phone Mirror website. Small helpers only: every page works without this file.

// "Download" buttons start the download, then show the page that explains how to open it.
document.querySelectorAll("a[data-then]").forEach(function (link) {
  link.addEventListener("click", function () {
    var next = link.getAttribute("data-then");
    setTimeout(function () { window.location.href = next; }, 900);
  });
});

// The "Copy" button next to the download's fingerprint.
document.querySelectorAll("button[data-copy]").forEach(function (button) {
  button.addEventListener("click", function () {
    var text = document.querySelector(button.getAttribute("data-copy")).textContent.trim();
    navigator.clipboard.writeText(text).then(function () {
      var before = button.textContent;
      button.textContent = "Copied";
      setTimeout(function () { button.textContent = before; }, 1600);
    });
  });
});

// Phone Mirror is a Mac app: say so to people who open the download page on something else.
var notMac = document.querySelector("[data-not-mac]");
if (notMac && !/Macintosh|Mac OS X/.test(navigator.userAgent)) {
  notMac.classList.add("show");
}

// The top bar is large at the top of the page and gets a little smaller with every bit of
// scrolling, until it is a small pill. --p goes from 0 (top) to 1 (scrolled SHRINK_OVER pixels);
// site.css turns that number into sizes.
var topBar = document.querySelector("header.top");
if (topBar) {
  var SHRINK_OVER = 420;
  var waiting = false;
  var resize = function () {
    waiting = false;
    var p = Math.min(1, Math.max(0, window.scrollY / SHRINK_OVER));
    topBar.style.setProperty("--p", p.toFixed(3));
  };
  window.addEventListener("scroll", function () {
    if (!waiting) { waiting = true; requestAnimationFrame(resize); }
  }, { passive: true });
  resize();
}

// The demo video on the home page.
//  - A short silent loop plays by itself while it is on screen (not for people who ask for less motion).
//  - The sound button swaps in the full film with music. Pressing it again turns the sound off and on.
//    When the film ends, the silent loop comes back.
//  - The other button pauses and resumes whichever one is showing.
var demo = document.querySelector("[data-demo]");
if (demo) {
  var loopVideo = demo.querySelector(".demo-loop");
  var filmVideo = demo.querySelector(".demo-film");
  var soundButton = demo.querySelector(".demo-sound");
  var soundLabel = soundButton.querySelector("span");
  var pauseButton = demo.querySelector(".demo-pause");
  var lessMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
  var pausedByPerson = lessMotion;   // with "reduce motion" on, nothing moves until asked
  var onScreen = false;

  var current = function () { return filmVideo.hidden ? loopVideo : filmVideo; };
  var play = function (video) { var started = video.play(); if (started) { started.catch(function () {}); } };

  var refresh = function () {
    var video = current();
    var sound = !filmVideo.hidden && !filmVideo.muted;
    demo.toggleAttribute("data-paused", video.paused);
    demo.toggleAttribute("data-sound", sound);
    soundButton.setAttribute("aria-pressed", sound ? "true" : "false");
    soundLabel.textContent = filmVideo.hidden ? "Play with sound" : (sound ? "Sound on" : "Sound off");
    pauseButton.setAttribute("aria-label", video.paused ? "Play the video" : "Pause the video");
  };

  var showLoop = function () {
    filmVideo.pause();
    filmVideo.hidden = true;
    loopVideo.hidden = false;
    if (onScreen && !pausedByPerson) { play(loopVideo); }
    refresh();
  };

  var showFilm = function () {
    loopVideo.pause();
    loopVideo.hidden = true;
    if (!filmVideo.poster && filmVideo.dataset.poster) { filmVideo.poster = filmVideo.dataset.poster; }
    filmVideo.hidden = false;
    filmVideo.muted = false;
    filmVideo.currentTime = 0;
    pausedByPerson = false;
    play(filmVideo);
    refresh();
  };

  soundButton.addEventListener("click", function () {
    if (filmVideo.hidden) { showFilm(); } else { filmVideo.muted = !filmVideo.muted; refresh(); }
  });
  pauseButton.addEventListener("click", function () {
    var video = current();
    pausedByPerson = !video.paused;
    if (video.paused) { play(video); } else { video.pause(); }
  });
  filmVideo.addEventListener("ended", showLoop);
  [loopVideo, filmVideo].forEach(function (video) {
    video.addEventListener("play", refresh);
    video.addEventListener("pause", refresh);
  });

  // Play only while the video is on screen.
  new IntersectionObserver(function (entries) {
    onScreen = entries[0].isIntersecting;
    var video = current();
    if (!onScreen) { video.pause(); } else if (!pausedByPerson) { play(video); }
  }, { threshold: 0.25 }).observe(demo);
  refresh();
}
