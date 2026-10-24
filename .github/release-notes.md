<!--
Release notes: the draft release starts from this file. Settings → About shows the items of the
first section (## 바뀐 것) in the app, so follow the rules in CLAUDE.md (Releases):
- One item per change: - **제목**: 설명
- 제목: a short noun phrase (about 10 characters), no period.
- 설명: the first sentence says what changed (About cuts it at two lines, about 70–80 characters);
  examples, exceptions and setting keys come after it.
- What a user notices, not how it was built; a fix says what works now. 3–5 items, biggest first.
-->
## 바뀐 것

- **변환 중 지우기**: 한자로 바꾼 뒤 Delete가 맥 일본어 입력기처럼 마지막 한 글자를 지우고 확정합니다(変換 → 変). 전에는 가나로 돌아갔습니다. 라이브 변환을 켰다면 맥과 같이 마지막 문절만 가나로 돌아가 한 글자 지워집니다(今日はいい天気 → 今日はいいてん).
- **라이브 변환 중 지우기**: 라이브 변환으로 한자가 보일 때 Delete가 마지막 문절을 가나로 돌리며 한 글자 지웁니다(漢字k → かんじ). 앞 문절은 보이던 대로 남고, 가나를 하나 더 치면 다시 변환됩니다.
- **Space 첫 후보**: 라이브 변환에서 끝 글자가 모음을 기다릴 때 Space가 첫 후보를 보여 줍니다(henkan → 変換). 전에는 한 칸 건너뛰어 返還이 나왔습니다.

## 설치·업데이트

설치 파일 [`Araso.pkg`](https://github.com/nyttastudio/araso/releases/latest/download/Araso.pkg)를 받아 열고 안내대로 설치하세요. 0.1.6 이상이라면 입력 메뉴나 설정 창의 **정보**에서 바로 업데이트할 수 있습니다.

Apple Silicon과 Intel을 함께 지원하는 유니버설 빌드이고, macOS 13 이상이 필요합니다. Developer ID로 서명하고 Apple 공증을 받았습니다.
