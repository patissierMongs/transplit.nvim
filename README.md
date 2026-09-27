# transplit.nvim

Neovim에서 **지금 보고 있는 것**을 파일의 문맥에 맞게 번역하고, 설명하고, 다이어그램으로 그려주는 플러그인이에요.
로그, man 페이지, `--help` 출력, Dockerfile·compose 같은 설정 파일, 소스 코드, 패킷 캡처까지 다뤄요.

- **번역:** 오른쪽 창에 원문과 **줄 단위로 1:1 정렬된** 번역을 띄우고, 스크롤과 커서를 같이 움직여요
- **설명:** 커서 줄(또는 선택 영역, 파일 전체)이 무슨 뜻이고, 앞뒤 문맥에서 어떤 의미인지, 실무에서 어떻게 대응하는지 알려줘요
- **시각화:** compose는 아키텍처·포트 매핑, 코드는 제어 흐름, 패킷은 대화 흐름과 헤더 구조로 그려요. nvim 안에서는 텍스트로, Emacs나 브라우저에서는 SVG로 봐요

> 기본 번역 언어와 UI는 한국어예요. `target = "Japanese"`처럼 바꾸면 UI는 영어로 전환돼요.

## 왜 만들었나 / 무엇이 다른가

LLM 번역 플러그인은 이미 많아요. transplit은 **"줄마다 LLM에 보내면 느리고, 값이 바뀌고, 문맥이 없다"**는 문제에서 출발했어요.

| 문제 | 해결 |
|---|---|
| 로그는 수천 줄인데 모양은 몇 가지뿐 | 시간·IP·경로·숫자를 `⟪a⟫`로 가리고 **고유한 패턴만 번역**한 뒤 값을 원래대로 복원. 로그 120줄 → 번역 대상 4개 |
| LLM이 IP나 경로를 바꿔버릴 위험 | 값은 애초에 LLM에 보내지 않음. 번역 결과에 자리표시자가 **정확히 같은 집합**으로 있을 때만 채택 |
| 한 줄만 보면 뜻을 모름 | 파일 경로·앞뒤 줄·폴더 구조로 **파일 요약(profile)**을 만들어 캐시하고 이후 요청마다 재사용 |
| LLM이 만든 다이어그램의 문법 오류 | D2를 로컬에서 컴파일해 검증하고, 오류를 모델에 되먹여 **자동 수정**(최대 2회) |

처음 구현에서 120줄 로그 번역이 **95초** 걸렸고, 위 설계와 CLI 옵션 조정으로 **9초**가 됐어요(두 번째부터는 캐시로 1초 안).
판단 과정과 측정은 [docs/DESIGN.md](docs/DESIGN.md)에 시간순으로 정리돼 있어요.

## 요구 사항

- Neovim **0.10+**
- LLM 백엔드 중 하나
  - [Claude Code](https://claude.com/claude-code) CLI (`claude`)
  - 또는 `$ANTHROPIC_API_KEY` + `curl` (CLI를 매번 띄우지 않아서 더 빠를 거예요. 아직 검증하지 않은 경로예요)
- 선택
  - [`d2`](https://d2lang.com): 시각화
  - `emacsclient`: SVG로 보기 (`ge`)
  - 브라우저: Mermaid 다이어그램 보기 (`gb`)
  - `tcpdump` 또는 `tshark`: `.pcap` 해석

`:checkhealth transplit`로 확인할 수 있어요.

## 설치 (lazy.nvim)

```lua
{
  "patissierMongs/swayHelper",
  name = "transplit.nvim",
  cmd = { "TransSplit", "TransExplain", "TransExplainFile", "TransVisual" },
  keys = {
    { "<leader>tk", "<cmd>TransSplit<cr>", desc = "Translate page" },
    { "<leader>tK", "<cmd>TransSplit!<cr>", desc = "Translate whole file" },
    { "<leader>te", "<cmd>TransExplain<cr>", mode = { "n", "x" }, desc = "Explain line/selection" },
    { "<leader>tE", "<cmd>TransExplainFile<cr>", desc = "Explain whole file" },
    { "<leader>tv", "<cmd>TransVisual<cr>", mode = { "n", "x" }, desc = "Visualize" },
  },
  opts = {},
}
```
`keys`를 쓰지 않고 `opts = { keymaps = true }`로 기본 단축키를 켤 수도 있어요.

## 사용법

| 명령 | 기본 키 (`keymaps = true`) | 동작 |
|---|---|---|
| `:TransSplit` | `<leader>tk` | 번역 창 열기/닫기. 현재 페이지 ± 1페이지, 스크롤하면 이어서 번역 |
| `:TransSplit!` | `<leader>tK` | 파일 전체 번역 (진행률 표시) |
| `:TransExplain` | `<leader>te` | 커서 줄 설명. visual 모드면 선택 영역 |
| `:TransExplainFile` | `<leader>tE` | 파일 전체 설명 |
| `:TransVisual` | `<leader>tv` | 시각화. visual 모드면 선택 영역 중심 |
| `:TransSplitRetry` | | 검증에 실패한 번역 다시 시도 |
| `:TransClearCache[!]` | | 현재 파일 캐시 삭제 (`!`는 전체) |

시각화 창 안에서:

| 키 | 동작 |
|---|---|
| `gs` | 원본 Markdown 편집. `:w`하면 모든 보기(nvim·Emacs·브라우저)가 다시 그려져요 |
| `ge` | Emacs에서 SVG로 보기 |
| `gb` | 브라우저에서 보기 (Mermaid 포함) |

어디서든 쓸 수 있어요.
```bash
nvim /var/log/nginx/error.log
man tar                                  # MANPAGER='nvim +Man!'
./configure --help | nvim -
docker logs web 2>&1 | nvim -
```

## 설정

기본값이에요. 필요한 것만 바꾸면 돼요.
```lua
require("transplit").setup({
  target = "Korean",        -- 번역·설명 언어
  ui_lang = nil,            -- "ko" | "en" | nil(target을 따름)
  backend = "auto",         -- "auto" | "api" | "cli"
  cli = "claude",
  translate = { cli_model = "haiku", api_model = "claude-haiku-4-5", batch = 40, context = 10, parallel = 3 },
  explain = { cli_model = "sonnet", api_model = "claude-sonnet-5", radius = 40 },
  visual = { cli_model = "sonnet", api_model = "claude-sonnet-5", open_cmd = nil },
  tree_depth = 2, tree_max = 80,   -- 폴더 구조: 깊이와 최대 항목 수
  body_max = 60000,                -- 이보다 큰 파일은 앞·뒤와 반복 패턴으로 요약
  related_max = 4,                 -- 함께 보낼 참조 파일 수
  keymaps = false,                 -- true 또는 { translate = "<leader>xx", ... }
})
```
전체 옵션은 `:help transplit`을 보세요.

## 무엇을 보내나 (프라이버시)

- 현재 버퍼의 일부 또는 전체
- 파일 경로, 크기, 파일 형식, 작업 폴더
- 폴더 구조: **이름과 크기만**, 깊이 2·최대 80개
- 현재 파일이 **상대 경로로 참조하는 파일**의 앞 200줄 (예: compose의 `./conf/nginx.conf`)
  - 절대 경로, 파일 폴더와 작업 폴더 밖의 파일, `.env`·키·비밀번호로 보이는 이름, 바이너리는 **보내지 않아요**

보내는 곳은 설정한 백엔드(Claude Code CLI 또는 Anthropic API)예요.

## 동반 도구: screen-explain

sway에서 키 하나로 **지금 화면**을 설명하고 이어서 질문하는 스크립트예요. [extras/screen-explain](extras/screen-explain)을 보세요.

## 개발

```bash
make deps    # plenary.nvim 받기 (lazy.nvim으로 설치돼 있으면 생략 가능)
make test    # 테스트 (plenary busted)
make lint    # stylua 검사
```

구조:
```
lua/transplit/
  init.lua        setup, 명령어, 단축키
  config.lua      기본값, UI 문구(ko/en)
  mask.lua        값 마스킹·복원·검증 (순수 함수)
  context.lua     파일 정보, 폴더 구조, 참조 파일, 큰 파일 요약
  cache.lua       번역·profile 디스크 캐시
  llm.lua         API/CLI 백엔드, 스트리밍
  translate.lua   번역 창 (scrollbind, 병렬 요청, 적응형 묶음 크기)
  explain.lua     줄·파일 설명
  visual/         D2 컴파일, 문서 변환, 로컬 HTTP 뷰어
  health.lua      :checkhealth
```

## 라이선스

MIT
