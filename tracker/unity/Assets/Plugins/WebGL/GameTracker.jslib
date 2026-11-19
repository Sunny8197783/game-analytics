// Unity WebGL → 브라우저의 window.GameTracker 로 마일스톤을 넘겨줍니다.
// WebGL 빌드의 index.html 에 game-tracker.js <script> 를 넣어야 동작합니다.
mergeInto(LibraryManager.library, {
  GameTracker_Milestone: function (namePtr, step) {
    var name = UTF8ToString(namePtr);
    if (window.GameTracker && window.GameTracker.milestone) {
      window.GameTracker.milestone(name, step);
    }
  }
});
