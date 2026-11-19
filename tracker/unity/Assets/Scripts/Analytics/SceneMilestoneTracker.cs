using UnityEngine;
using UnityEngine.SceneManagement;

/// <summary>
/// 선택 사항: 씬이 열릴 때마다 자동으로 마일스톤을 남깁니다.
/// 첫 씬에 빈 GameObject 를 만들고 이 컴포넌트를 붙인 뒤,
/// sceneSteps 에 씬 이름과 순서를 적어주세요. (빌드 인덱스를 쓰려면 비워두세요)
/// </summary>
public class SceneMilestoneTracker : MonoBehaviour
{
    [System.Serializable] public struct SceneStep { public string sceneName; public int step; public string label; }
    public SceneStep[] sceneSteps;

    void Awake()
    {
        DontDestroyOnLoad(gameObject);
        SceneManager.sceneLoaded += (scene, _) =>
        {
            foreach (var s in sceneSteps)
                if (s.sceneName == scene.name) { GameTracker.Milestone(string.IsNullOrEmpty(s.label) ? s.sceneName : s.label, s.step); return; }
            if (sceneSteps == null || sceneSteps.Length == 0)
                GameTracker.Milestone(scene.name, scene.buildIndex + 1);
        };
    }
}
