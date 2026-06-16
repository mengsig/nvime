-- nvime.fslock
--
-- Tiny advisory file-lock + atomic-write helper for the JSON/JSONL ledgers
-- (audit, usage, attribution). Those ledgers are the durable proof that every
-- AI edit was explicit, gated, and attributed; two Neovim instances open on
-- the same repo (or an editor running alongside CI) must never interleave
-- appends or clobber each other's full rewrites. This module is the single
-- place that serializes those writes.
--
-- It depends only on vim.uv and degrades safely by design:
--   * a contended lock returns nil, "locked" instead of blocking the editor;
--   * a crashed holder's stale lock is stolen after a timeout;
--   * atomic_write never leaves a readable partial file at the target path.

local M = {}

local uv = vim.uv or vim.loop

local MODE_LOCK = tonumber("600", 8)
local MODE_FILE = tonumber("644", 8)
local DEFAULT_STALE_SECONDS = 10
local SPIN_ATTEMPTS = 5
local SPIN_INTERVAL_MS = 15

local function pid()
  return vim.fn.getpid()
end

-- Best-effort: stamp the lock with our pid + acquire time for humans debugging
-- a wedged lock. Never fatal — the file's existence is the signal, the
-- contents are only diagnostics.
local function stamp_lock(fd)
  pcall(function()
    uv.fs_write(fd, string.format("%d %d\n", pid(), os.time()))
  end)
end

-- One attempt to exclusively create the lock file. Returns true on success.
local function try_acquire(lockpath)
  local fd = uv.fs_open(lockpath, "wx", MODE_LOCK)
  if not fd then
    return false
  end
  stamp_lock(fd)
  pcall(uv.fs_close, fd)
  return true
end

local function lock_is_stale(lockpath, stale_seconds)
  local st = uv.fs_stat(lockpath)
  if not st or not st.mtime then
    -- Vanished between checks; treat as acquirable.
    return true
  end
  return (os.time() - (st.mtime.sec or 0)) > stale_seconds
end

-- Run fn() while holding an advisory lock on `path`. The lock file is
-- `path .. ".lock"`. Returns fn()'s results on success; returns nil, "locked"
-- when the lock could not be acquired, and nil, <error> when fn() itself
-- errors — callers treat both as a soft failure (no uncaught throw escapes).
function M.with_lock(path, fn, opts)
  opts = opts or {}
  local stale_seconds = tonumber(opts.stale_seconds) or DEFAULT_STALE_SECONDS
  local lockpath = path .. ".lock"

  local acquired = try_acquire(lockpath)
  if not acquired then
    -- Bounded retry for transient contention; the protected writes are tiny.
    for _ = 1, SPIN_ATTEMPTS do
      uv.sleep(SPIN_INTERVAL_MS)
      if try_acquire(lockpath) then
        acquired = true
        break
      end
    end
  end
  if not acquired and lock_is_stale(lockpath, stale_seconds) then
    -- A crashed holder left the lock behind; steal it once.
    pcall(uv.fs_unlink, lockpath)
    acquired = try_acquire(lockpath)
  end
  if not acquired then
    return nil, "locked"
  end

  local ok, a, b = pcall(fn)
  pcall(uv.fs_unlink, lockpath)
  if not ok then
    return nil, a
  end
  return a, b
end

-- Atomically replace `path` with `data`: write to a per-pid temp in the SAME
-- directory (so the rename stays on one filesystem and is atomic even when
-- the ledger dir is a separate mount), fsync, then rename over the target.
-- Returns true on success, or false, <error>. Never leaves a readable partial
-- file at `path`.
function M.atomic_write(path, data)
  local tmp = string.format("%s.tmp.%d", path, pid())
  local fd, open_err = uv.fs_open(tmp, "w", MODE_FILE)
  if not fd then
    return false, open_err
  end
  local ok, err = pcall(function()
    local written, werr = uv.fs_write(fd, data)
    if not written then
      error(werr or "write failed")
    end
    uv.fs_fsync(fd)
  end)
  pcall(uv.fs_close, fd)
  if not ok then
    pcall(uv.fs_unlink, tmp)
    return false, err
  end
  local renamed, rename_err = uv.fs_rename(tmp, path)
  if not renamed then
    pcall(uv.fs_unlink, tmp)
    return false, rename_err
  end
  return true
end

return M
