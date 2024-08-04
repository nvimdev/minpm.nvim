local api, stdpath, uv = vim.api, vim.fn.stdpath, vim.uv
local repos, INSTALL, UPDATE = {}, 0, 1
local data_dir = stdpath('data')
---@diagnostic disable-next-line: param-type-mismatch
local STARTDIR = vim.fs.joinpath(data_dir, 'site', 'minpm', 'start')
---@diagnostic disable-next-line: param-type-mismatch
local OPTDIR = vim.fs.joinpath(data_dir, 'site', 'minpm', 'opt')

local function as_table(data)
  return type(data) ~= 'table' and { data } or data
end

local use_meta = {}
use_meta.__index = use_meta
function use_meta:event(e)
  self.event = as_table(e)
  self.islazy = true
  return self
end

function use_meta:ft(ft)
  self.ft = as_table(ft)
  self.islazy = true
  return self
end

function use_meta:setup(config)
  self.setup = config
  return self
end

function use_meta:config(config)
  assert(type(config) == 'function')
  self.config = config
  return self
end

local function info_win()
  local bufnr = api.nvim_create_buf(false, false)
  local win = api.nvim_open_win(bufnr, true, {
    relative = 'editor',
    height = math.floor(vim.o.lines * 0.5),
    width = math.floor(vim.o.columns * 0.8),
    row = 3,
    col = 10,
    border = 'rounded',
    noautocmd = true,
  })
  vim.wo[win].wrap = false
  return win, bufnr
end

local bufnr, winid

local function handle_git_output(index, data)
  vim.schedule(function()
    if not winid then
      winid, bufnr = info_win()
    end
    api.nvim_buf_set_lines(bufnr, index - 1, index, false, { data })
  end)
end

function use_meta:do_action(index, action)
  local tail = vim.split(self.name, '/')[2]
  local path = vim.fs.joinpath(self.islazy and OPTDIR or STARTDIR, tail)
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
    end))
  end)
end

local function action(act)
  local index = 0
  vim.iter(repos):map(function(repo)
    index = index + 1
    repo:do_action(index, act)
  end)
end

return {
  use = function(name)
    local repo = setmetatable({ name = name }, use_meta)
    repos[#repos + 1] = repo
    return repo
  end,
  install = function()
    action(INSTALL)
  end,
  update = function()
    action(UPDATE)
  end,
}
