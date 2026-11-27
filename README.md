# expl.nvim

**expl** explains the code you select with Claude. The explanation appears in a popup next to the selection. Read it, press `q`, and carry on.

It runs your installed [Claude Code](https://claude.com/claude-code) CLI, so it uses your existing Claude subscription. You don't need an API key.

## Usage

1. Select some code in visual mode (`v`, `V` or `<C-v>`).
2. Press `<leader>ce`, or run `:Expl` to explain your last selection.
3. A popup opens next to the selection, and the explanation appears as Claude writes it.
4. In the popup:

| Key | Does |
| --- | --- |
| `f` | Ask a follow-up question. Claude remembers the code and its answer |
| `r` | Refresh: ignore the cached answer and ask Claude again |
| `q` / `<Esc>` | Close (moving to another window closes it too) |

`:ExplClearCache` deletes all cached explanations.

## What it does, step by step

### 1. Reads the selection

`get_selection()` reads the selected text with `vim.fn.getregion()`, so character-wise, line-wise and block-wise selections all work. When it's run from `:Expl` (after visual mode has ended), it uses the `'<` and `'>` marks instead.

### 2. Builds the prompt

`build_prompt()` sends Claude:

- the file name, filetype and line numbers
- up to 40 lines before and after the selection (`context_lines`), with a `<<< SELECTION >>>` marker where the selection sits. These lines are context only and aren't explained.
- the selected code itself, in a fenced code block

A system prompt sets the style of the answer:

- one sentence on what the code does and why
- a short walkthrough of the key steps as bullets, with names in `backticks`
- an optional `Note:` line for a gotcha or non-obvious idiom
- a tiny fenced snippet if one helps
- no preamble or wrap-up, aiming for under 150 words

### 3. Opens the popup

`win_opts()` decides where the popup goes:

1. **to the right** of the longest selected line, if there's room
2. otherwise **below** the selection
3. otherwise **above** it

It starts one line tall. As text arrives, `resize()` grows it to fit (wrapped lines included), up to `max_height`. The popup has the focus, so you can scroll it.

### 4. Calls Claude

It runs the `claude` CLI in the background with `vim.system()`, so the editor never freezes:

```sh
claude -p \
  --output-format stream-json --verbose --include-partial-messages \
  --system-prompt "<expl prompt>" \
  --tools "" \
  --strict-mcp-config \
  --setting-sources "" \
  --model sonnet
  # follow-ups add: --resume <session-id>
```

| Flag | Why |
| --- | --- |
| `-p` | Non-interactive mode: read the prompt from stdin, print the answer, exit |
| `--output-format stream-json --include-partial-messages` | Emit the answer in small pieces, so the popup fills in as Claude writes |
| `--system-prompt` | Replace Claude Code's default coding-agent prompt with expl's short "explain" prompt |
| `--tools ""` | No tools: Claude can't read files, run commands or edit anything |
| `--strict-mcp-config` | Don't load any of your MCP servers |
| `--setting-sources ""` | Ignore your Claude Code settings, hooks and project config |
| `--resume <id>` | Follow-ups only: continue the same conversation, so Claude remembers the code |
| `--model sonnet` | A fast model for quick explanations (configurable) |

The CLI runs from Neovim's cache folder rather than your project, so it doesn't pick up project files such as `CLAUDE.md`. The prompt goes in through stdin, not as a command-line argument.

### 5. Shows the answer as it arrives

The CLI prints one JSON event per line. expl keeps any half-received line until the rest arrives, then reads each complete line:

- `text_delta` events: the text is added to the end of the popup (`append()`)
- a `result` event with `is_error`: the error message is shown in the popup
- if the CLI exits with an error before any text arrived, its exit code and error output are shown

While Claude is working, the title shows a spinner (` expl ⠋ `). It changes back to ` expl ` when the answer is complete.

### 6. Caches the answer

Each finished explanation is saved to `stdpath("cache")/expl/<hash>.md`. The hash covers the selected code, the filetype, the model and the system prompt, but not the surrounding lines, so the same code gets the same answer even after nearby edits. Explaining identical code again shows the saved answer instantly, with no request to Claude, and the footer says `cached · r refresh`. Errors and cancelled answers are never cached, and follow-ups aren't either. Set `cache = false` to turn it off.

### 7. Follow-up questions

Press `f` and type a question. expl adds it to the popup under a `---` line and sends it with `--resume <session-id>`, using the session ID from the CLI's first `init` event. Claude sees the whole conversation, including the code.

If the explanation came from the cache, there's no session yet. The first follow-up then starts a new one that includes the original prompt and the cached answer, so Claude still knows what "it" said.

### 8. Cleans up

`close()` runs when you press `q` or `<Esc>`, when you leave the popup, or when you start another explanation. It:

- stops the `claude` process if it's still running
- stops the spinner
- closes the popup window (the buffer is wiped with it)
- deletes the popup's Claude session files from `~/.claude/projects/` (half a second later, so a stopped process has finished writing). Follow-ups need sessions saved while the popup is open, but they never pile up in your `claude --resume` history. Quitting Neovim with the popup open deletes them too.

Each piece of streamed text checks that it belongs to the current request, so late output from a cancelled request never lands in a newer popup.

## Look and highlighting

- The popup buffer has the `markdown` filetype, and treesitter is started on it. Fenced code blocks are highlighted using each block's language, and inline `code` stands out.
- `wrap`, `linebreak` and `conceallevel = 2` give clean wrapped text without visible Markdown symbols. If [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) is installed, it adds its own styling.
- Colors come from four highlight groups, mapped onto the popup with `winhighlight`:

| Group | Colors | Default |
| --- | --- | --- |
| `ExplNormal` | text and background | `NormalFloat` |
| `ExplBorder` | border | `FloatBorder` |
| `ExplTitle` | title | `FloatTitle` |
| `ExplFooter` | "q to close" footer | `FloatFooter` |

A group you set in `highlights` replaces its default completely. The groups are reapplied on every `ColorScheme` event, so switching themes doesn't reset them.

## Configuration

Defaults:

```lua
require("expl").setup({
  cmd = "claude",          -- path to the Claude Code CLI
  model = "sonnet",        -- any `claude --model` value; nil = your CLI default
  context_lines = 40,      -- lines of context sent on each side of the selection
  width = 72,
  max_height = 30,
  border = "rounded",      -- "single", "double", "solid", "none", ...
  cache = true,            -- reuse answers for identical code
  highlights = {
    ExplNormal = { link = "NormalFloat" },
    ExplBorder = { link = "FloatBorder" },
    ExplTitle  = { link = "FloatTitle" },
    ExplFooter = { link = "FloatFooter" },
  },
  system_prompt = [[ ... ]],
})
```

Installed with lazy.nvim from a local folder (see `lua/plugins/expl.lua`):

```lua
{
  name = "expl",
  dir = vim.fn.stdpath("config") .. "/expl.nvim",
  opts = {
    highlights = {
      ExplNormal = { fg = "#ededed", bg = "#1f1f1f" },
      ExplBorder = { fg = "#52a8ff", bg = "#1f1f1f" },
      ExplTitle  = { fg = "#c472fb", bg = "#1f1f1f", bold = true },
      ExplFooter = { fg = "#676767", bg = "#1f1f1f", italic = true },
    },
  },
  keys = {
    { "<leader>ce", function() require("expl").explain() end, mode = "x", desc = "Explain selection (expl)" },
  },
}
```

## Requirements

Run `:checkhealth expl` to check all of these. Full docs are in `:h expl`.

- Neovim 0.10 or newer (needs `vim.fn.getregion`, `vim.system` and `nvim_win_text_height`)
- the `claude` CLI on your `PATH`, signed in to your Claude account
- optional: treesitter parsers for `markdown`, `markdown_inline` and the languages you read
