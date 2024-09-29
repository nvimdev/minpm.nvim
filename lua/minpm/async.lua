local function wrap_async(func)
  return function(...)
    local args = { ... }
    return function(callback)
      table.insert(args, callback)
      func(unpack(args))
    end
  end
end

local function await(promise)
  local co = coroutine.running()
  promise(function(...)
    local args = { ... }
    vim.schedule(function()
      assert(coroutine.resume(co, unpack(args)))
    end)
  end)
  return coroutine.yield()
end

local function async(func)
  return function(...)
    local co = coroutine.create(func)
    local function step(...)
      local ok, err = coroutine.resume(co, ...)
      if not ok then
        error(err)
      end
    end
    step(...)
  end
end

return {
  async_fs_fstat = wrap_async(vim.uv.fs_fstat),
  async = async,
  await = await,
}
