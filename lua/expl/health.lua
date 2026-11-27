
local M = {}

local health = vim.health

local function check_neovim()
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10 or newer is required", { "Upgrade Neovim" })
  end
end

local function check_claude(cfg)
  if vim.fn.executable(cfg.cmd) == 0 then
    health.error(("`%s` not found in PATH"):format(cfg.cmd), {
      "Install Claude Code: https://claude.com/claude-code",
      "Or point `cmd` at the binary in expl's setup()",
    })
    return
  end

  local version = vim.system({ cfg.cmd, "--version" }, { text = true }):wait(10000)
  if version.code == 0 then
    health.ok(("`%s` %s"):format(cfg.cmd, vim.trim(version.stdout)))
  else
    health.error(("`%s --version` failed"):format(cfg.cmd), { vim.trim(version.stderr or "") })
    return
  end

  local res = vim.system({ cfg.cmd, "auth", "status" }, { text = true }):wait(15000)
  local ok, status = pcall(vim.json.decode, res.stdout or "")
  if res.code ~= 0 or not ok or type(status) ~= "table" then
    health.warn("Couldn't read sign-in status from `claude auth status`", {
      "Run `claude` in a terminal to check you're signed in",
    })
  elseif not status.loggedIn then
    health.error("Claude Code isn't signed in", { "Run `claude auth login` in a terminal" })
  elseif status.authMethod == "claude.ai" then
    local plan = status.subscriptionType and (" (" .. status.subscriptionType .. " plan)") or ""
    health.ok("Signed in with your Claude subscription" .. plan)
  else
    health.warn(("Signed in with `%s`, not a Claude subscription"):format(tostring(status.authMethod)), {
      "Explanations are billed to that account per use",
      "Run `claude auth login` to use your subscription instead",
    })
  end

  health.info("Model: " .. (cfg.model or "your Claude Code default"))
end

local function check_treesitter()
  for _, lang in ipairs({ "markdown", "markdown_inline" }) do
    local ok, found = pcall(vim.treesitter.language.add, lang)
    if ok and found then
      health.ok(("Treesitter parser `%s` found"):format(lang))
    else
      health.warn(("Treesitter parser `%s` not found"):format(lang), {
        "Explanations will show without Markdown and code highlighting",
        ("Install it with `:TSInstall %s`"):format(lang),
      })
    end
  end
  health.info("Code blocks are highlighted with each language's own parser, when it's installed")

  if pcall(require, "render-markdown") then
    health.ok("render-markdown.nvim found (adds extra Markdown styling)")
  else
    health.info("Optional: render-markdown.nvim adds extra Markdown styling")
  end
end

local function check_cache(cfg)
  if not cfg.cache then
    health.info("Cache is off (`cache = false`)")
    return
  end
  local dir = vim.fn.stdpath("cache") .. "/expl"
  local files = vim.fn.glob(dir .. "/*.md", false, true)
  health.ok(("Cache is on: %d explanation(s) in %s"):format(#files, dir))
end

function M.check()
  local cfg = require("expl").config

  health.start("expl: Neovim")
  check_neovim()

  health.start("expl: Claude Code")
  check_claude(cfg)

  health.start("expl: highlighting")
  check_treesitter()

  health.start("expl: cache")
  check_cache(cfg)
end

return M
