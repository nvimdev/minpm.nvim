local api, stdpath, uv = vim.api, vim.fn.stdpath, vim.uv
local repos, INSTALL, UPDATE = {}, 0, 1
local buf_set_lines, create_autocmd = api.nvim_buf_set_lines, api.nvim_create_autocmd
local packadd = vim.cmd.packadd
local exec_autocmds = api.nvim_exec_autocmds
local data_dir = stdpath('data')
---@diagnostic disable-next-line: param-type-mismatch
local STARTDIR = vim.fs.joinpath(data_dir, 'site', 'pack', 'minpm', 'start')
---@diagnostic disable-next-line: param-type-mismatch
local OPTDIR = vim.fs.joinpath(data_dir, 'site', 'pack', 'minpm', 'opt')
---@diagnostic disable-next-line: param-type-mismatch
vim.opt.packpath:prepend(vim.fs.joinpath(data_dir, 'site'))
local bufnr, winid

local function as_table(data)
  return type(data) ~= 'table' and { data } or data
end

local use_meta = {}
use_meta.__index = use_meta
function use_meta:event(e)
  self.event = as_table(e)
  self.islazy = true
  local triggered = false
  create_autocmd(e, {
    callback = function(args)
      if not triggered and self.remote then
        triggered = true
        packadd(self.tail)
        exec_autocmds(e, {
          modeline = false,
          data = args.data,
        })
        if self.setup_config then
          module = self.tail:gsub('%.nvim', '') or self.tail:gsub('-nvim', '')
          require(module).setup(self.setup_config)
        end
      end
    end,
  })
  return self
end

function use_meta:ft(ft)
  self.ft = as_table(ft)
  self.islazy = true
  return self
end

function use_meta:setup(config)
  self.setup_config = config
  return self
end

function use_meta:config(config)
  assert(type(config) == 'function')
  self.config = config
  return self
end

local function info_win()
  bufnr = api.nvim_create_buf(false, false)
  local win = api.nvim_open_win(bufnr, true, {
    relative = 'editor',
    height = math.floor(vim.o.lines * 0.5),
    width = math.floor(vim.o.columns * 0.8),
    row = 3,
    col = 10,
    border = 'rounded',
    noautocmd = true,
    style = 'minimal',
  })
  vim.wo[win].wrap = false
  vim.bo[bufnr].buftype = 'nofile'
  return win, bufnr
end

local function handle_git_output(index, data)
  vim.schedule(function()
    if not winid then
      winid, bufnr = info_win()
    end
    buf_set_lines(bufnr, index - 1, index, false, { data })
  end)
end

function use_meta:do_action(index, action, on_complete)
  local path = vim.fs.joinpath(self.islazy and OPTDIR or STARTDIR, self.tail)
  local url = ('https://github.com/%s'):format(self.name)
  local cmd = action == INSTALL and { 'git', 'clone', '--progress', url, path }
    or { 'git', '-C', '--progress', path, 'pull' }
  uv.fs_stat(path, function(_, stat)
    if stat and stat.type == 'directory' then
      return
    end
    coroutine.resume(coroutine.create(function()
      local co = assert(coroutine.running())
      vim.system(cmd, {
        timeout = 5000,
        stderr = function(err, data)
          coroutine.resume(co, err, data)
        end,
      })
      while true do
        local err, data = coroutine.yield()
        if not data then
          break
        end
        local lines = err and err or data
        lines = lines:gsub('\r', '\n'):gsub('\n+', '\n')
        lines = vim.split(lines, '\n', { trimempty = true })
        handle_git_output(index, ('%s: %s'):format(self.name, lines[#lines]))
      end
      on_complete()
    end))
  end)
end

local function action(act)
  local index = 0
  local completed_count = 0
  local function on_complete()
    completed_count = completed_count + 1
    if completed_count == index then
      vim.schedule(function()
        if winid then
          api.nvim_win_close(winid, true)
          winid = nil
          bufnr = nil
          vim.notify('[Minpm] All plugins installed please restart neovim', vim.log.levels.WARN)
        end
      end)
    end
  end

  vim.iter(repos):map(function(repo)
    if not repo.remote then
      return
    end
    index = index + 1
    repo:do_action(index, act, on_complete)
  end)
end

return {
  use = function(name)
    name = vim.fs.normalize(name)
    local parts = vim.split(name, '/', { trimempty = true })
    repos[#repos + 1] = setmetatable({
      name = name,
      remote = not name:find(vim.env.HOME),
      tail = parts[#parts],
    }, use_meta)
    return repos[#repos]
  end,
  install = function()
    action(INSTALL)
  end,
  update = function()
    action(UPDATE)
  end,
}
