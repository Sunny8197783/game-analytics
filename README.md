# 게임 분석실 (game-analytics)

8개 게임의 **방문자 · 재방문 · 체류시간 · 마일스톤 이탈 지점**을 한 화면에서 보는 대시보드.

```
game-analytics/
├─ index.html                     대시보드 (GitHub Pages 에 그대로 올림)
├─ supabase/schema.sql            DB: 테이블 + 보안 규칙 + 분석 함수
└─ tracker/
   ├─ game-tracker.js             각 게임에 넣는 기록기 (script 한 줄)
   └─ unity/Assets/...            재앙의 용사(Unity WebGL)용 플러그인
```

## 설치 (약 15분)

1. **Supabase** 무료 프로젝트 생성 (지역: Seoul)
2. SQL Editor → `supabase/schema.sql` 전체 붙여넣고 **Run**, 이어서 `supabase/players.sql` 도 **Run** (플레이어·구간 분석)
3. Authentication → Users → **Add user** 로 내 계정 생성 후 SQL Editor 에서
   ```sql
   insert into public.admins (user_id)
   select id from auth.users where email = '내이메일@example.com'
   on conflict do nothing;
   ```
   그리고 Sign In / Providers 에서 **Allow new users to sign up 끄기**
4. 이 폴더를 새 저장소 `Sunny8197783/game-analytics` 로 push → Settings → Pages → main
5. `https://sunny8197783.github.io/game-analytics/` 열기 → 오른쪽 위 **데모 데이터** 버튼 →
   Project URL, Publishable key(Settings → API Keys), 관리자 이메일/비번 입력
6. 대시보드의 **설치 가이드** 탭에서 게임별 script 한 줄 + 마일스톤 코드를 복사해 각 게임에 붙여넣기

## 무엇을 어떻게 재나

| 지표 | 정의 |
|---|---|
| 방문자 | 브라우저마다 무작위 ID(localStorage). 같은 기기·브라우저면 같은 사람 |
| 접속(세션) | 페이지를 열 때마다 1회. 새로고침이나 30분 안에 돌아오면 같은 접속으로 이어짐 |
| 재방문율 | 기간 안에 2번 이상 접속한 사람 ÷ 방문자 |
| 체류시간 | 화면을 보고 있고 90초 안에 조작이 있었던 시간만 합산 (켜두고 자리 비움은 제외) |
| 마일스톤 도달 | `GameTracker.milestone('이름', step)` 을 밟은 사람 수 |
| 여기서 멈춤 | 기간 중 그 사람이 마지막으로 도달한 지점 = 이탈 지점 |
| 구간 | 한 지점에 처음 도착 ~ 다음 지점에 처음 도착까지 실제 플레이 시간 (누적 플레이 기준이라 여러 번 나눠 접속해도 이어짐) |
| 플레이어 상태 | 완주 = 마지막 지점 도달 · 진행 중 = 3일 안에 플레이 · 휴면 = 3–14일 · 이탈 = 14일 넘게 안 옴 |

## 보안

- 게임(공개 키)은 기록을 **쓰기만** 가능. 읽기·수정·삭제 불가.
- 읽기는 `admins` 에 등록된 로그인 계정만 가능 (RLS).
- 개인정보(IP, 이름 등)는 저장하지 않음. 방문자 ID는 무작위 UUID.

## 참고

- claude.ai 안에서 여는 미리보기는 외부 DB 연결이 막혀 데모 데이터만 보입니다. 실제 연결은 GitHub Pages 에 올린 주소에서 하세요.
- 무료 플랜 DB 500MB 기준, 15초 하트비트로 약 수백만 행(수만 시간 플레이)까지 충분합니다.
