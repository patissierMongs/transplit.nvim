local M = {}

---@class transplit.Config
M.defaults = {
  -- language translations and explanations are written in
  target = "Korean",
  -- language of the plugin's own UI and section headings: "ko", "en", or nil to follow `target`
  ui_lang = nil,
  -- "auto": the Anthropic API via curl when $ANTHROPIC_API_KEY is set, else the `claude` CLI
  -- "api" | "cli": force one of them
  backend = "auto",
  cli = "claude",

  head = 15, -- lines from the top of a file used to build its profile
  tail = 15, -- lines from the bottom
  tree_depth = 2,
  tree_max = 80, -- entries per directory tree
  body_max = 60000, -- bytes of a file sent verbatim for whole-file explain/visualize
  related_max = 4, -- files referenced by relative path (./conf/nginx.conf, build: ./app, ...)

  translate = {
    cli_model = "haiku",
    api_model = "claude-haiku-4-5",
    max_tokens = 8192,
    batch = 40, -- unique templates per request
    context = 10, -- lines around the cursor sent for meaning
    parallel = 3, -- concurrent requests in whole-file mode
  },
  explain = { cli_model = "sonnet", api_model = "claude-sonnet-5", max_tokens = 8192, radius = 40 },
  visual = {
    cli_model = "sonnet",
    api_model = "claude-sonnet-5",
    max_tokens = 16000,
    -- argv the viewer URL is appended to; nil = `firefox --new-window` if available, else vim.ui.open
    open_cmd = nil,
  },

  cache_file = vim.fn.stdpath("cache") .. "/transplit/cache.json",
  visual_dir = vim.fn.stdpath("cache") .. "/transplit/visual",

  -- false, true (defaults below), or a table overriding some of them
  keymaps = false,
}

M.default_keymaps = {
  translate = "<leader>tk",
  translate_whole = "<leader>tK",
  explain = "<leader>te",
  explain_file = "<leader>tE",
  visualize = "<leader>tv",
}

local messages = {
  en = {
    translating = "translating",
    whole = "whole file",
    failed_patterns = "%d patterns failed (:TransSplitRetry)",
    analyzing = "Analyzing…",
    explanation = "Explanation",
    whole_file = "(whole file)",
    failed = "Failed",
    visual = "Visualization",
    visual_hint = "gs edit source · ge Emacs · gb browser",
    generating = "Generating…",
    compiling = "Compiling D2…",
    fixing = "Fixing diagram syntax (%d/2)",
    fix_gave_up = "Automatic fix failed: edit with gs, then :w",
    fix_failed = "Fix failed: %s",
    gen_failed = "Generation failed: %s",
    d2_error = "D2 error",
    no_text_render = "(cannot be drawn as text: view with ge/gb)",
    mermaid_in_browser = "Mermaid diagram: view with gb (browser)",
    mermaid_org = "Mermaid diagram: open with gb in nvim",
    viewer_loading = "Loading…",
    viewer_error = "Mermaid error",
    viewer_disconnected = "nvim disconnected",
    guess = "(guess)",
    sections_line = { "Meaning", "Context", "In practice", "See also" },
    sections_file = { "Overview", "Structure", "Key points", "Watch out", "Next steps" },
  },
  ko = {
    translating = "번역 중",
    whole = "전체",
    failed_patterns = "%d개 패턴 실패 (:TransSplitRetry)",
    analyzing = "분석 중…",
    explanation = "설명",
    whole_file = "(전체)",
    failed = "실패",
    visual = "시각화",
    visual_hint = "gs 원본 편집 · ge Emacs · gb 브라우저",
    generating = "생성 중…",
    compiling = "D2 컴파일 중…",
    fixing = "다이어그램 문법 오류 수정 중 (%d/2)",
    fix_gave_up = "자동 수정 실패 — gs로 직접 고친 뒤 :w",
    fix_failed = "수정 실패: %s",
    gen_failed = "생성 실패: %s",
    d2_error = "D2 오류",
    no_text_render = "(텍스트로 그릴 수 없는 다이어그램 — ge/gb로 보기)",
    mermaid_in_browser = "Mermaid 다이어그램 — gb(브라우저)에서 보기",
    mermaid_org = "Mermaid 다이어그램: nvim에서 gb로 브라우저에서 보기",
    viewer_loading = "불러오는 중…",
    viewer_error = "Mermaid 오류",
    viewer_disconnected = "nvim 연결 끊김",
    guess = "(추정)",
    sections_line = { "의미", "문맥", "실무 포인트", "참고" },
    sections_file = { "개요", "구조", "핵심 내용", "주의할 점", "다음 단계" },
  },
}

---@type transplit.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

---UI language: explicit `ui_lang`, else Korean UI for a Korean target, else English.
function M.lang()
  local o = M.options
  if o.ui_lang and messages[o.ui_lang] then
    return o.ui_lang
  end
  return o.target:lower():find("korean") and "ko" or "en"
end

---@param key string
function M.msg(key)
  local lang = messages[M.lang()]
  return lang[key] or messages.en[key]
end

return M
