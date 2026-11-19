using System.Runtime.InteropServices;
using UnityEngine;
using UnityEngine.SceneManagement;

/// <summary>
/// 게임 분석 트래커 (Unity WebGL 용).
/// 사용: GameTracker.Milestone("보스 1 처치", 5);
/// 접속·체류시간은 브라우저 쪽 game-tracker.js 가 자동으로 기록합니다.
/// 에디터나 WebGL 이 아닌 빌드에서는 로그만 찍고 아무것도 보내지 않습니다.
/// </summary>
public static class GameTracker
{
#if UNITY_WEBGL && !UNITY_EDITOR
    [DllImport("__Internal")] private static extern void GameTracker_Milestone(string name, int step);
#endif

    public static void Milestone(string name, int step)
    {
#if UNITY_WEBGL && !UNITY_EDITOR
        GameTracker_Milestone(name, step);
#else
        Debug.Log($"[GameTracker] milestone '{name}' step {step}");
#endif
    }
}
