# screen-explain

transplit.nvim의 동반 도구예요. **지금 화면**을 LLM이 설명해 주고, 이어서 질문할 수 있어요. sway(Wayland) 전용이에요.

- 키 한 번: 화면을 캡처해서 포커스된 창 오른쪽에 새 pane(foot)을 열고 설명을 스트리밍해요
- 0.4초 안에 두 번: 같은 pane에서 질문부터 입력받아요
- 답이 끝나면 `추가 질문`을 계속할 수 있고, 빈 Enter를 치면 nvim 읽기 전용 모드로 대화 전체를 보여줘요(`q`로 닫기)

## 필요한 것
`sway`, `grim`, `foot`, `python3`, `nvim`, [Claude Code](https://claude.com/claude-code) CLI(`claude`)

## 설치
```bash
ln -s "$PWD/screen-explain" ~/.local/bin/screen-explain
```
sway 설정 (ThinkPad의 ThinkVantage 키 예시, 다른 키도 가능):
```
bindcode --no-repeat 156 exec ~/.local/bin/screen-explain --tap
```
키 코드는 `wev`로 확인해요. 일반 키라면 `bindsym $mod+F1 exec ~/.local/bin/screen-explain --tap`처럼 연결해도 돼요.

## 보내는 것
- 포커스된 출력(모니터)의 스크린샷
- 포커스된 창의 앱 이름·제목, 터미널이라면 안에서 실행 중인 명령과 작업 폴더
- 파일 내용은 읽지 않아요

**스크린샷은 Anthropic으로 전송돼요.** 비밀번호나 개인 정보가 보이는 화면에서는 쓰지 마세요. 결과는 `~/.cache/screen-explain/<시각>/`에, 실행 기록과 오류는 `$XDG_RUNTIME_DIR/screen-explain.log`에 남아요.

## 설계 메모
- **길게 누르기 대신 두 번 누르기:** ThinkVantage는 EC 핫키라 커널이 누르기·떼기를 동시에 보내요. 누른 시간을 잴 수 없어서 두 번 누르기로 모드를 나눠요. 한 번 눌렀을 때 두 번째 입력을 기다리느라 0.4초 늦게 떠요(`DOUBLE_TAP`).
- **입력 프롬프트:** 색상 코드를 `\001…\002`로 감싸요. 안 그러면 readline이 줄 폭을 잘못 세서 긴 질문이 첫 줄을 덮어써요.
- **후속 질문:** 매 턴마다 스크린샷을 다시 읽고 이전 질문·답변을 `<previous_turns>`로 함께 보내요.

자세한 경위는 [../../docs/DESIGN.md](../../docs/DESIGN.md)의 2026-09-19~20 항목을 보세요.
