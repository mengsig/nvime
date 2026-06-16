-- nvime.schema
--
-- Version reconciliation for the JSON ledgers (usage, attribution). The
-- ledgers carry a `version` field; this module decides what version the
-- running code should treat an on-disk ledger as, and — critically — never
-- silently DOWN-grades a ledger written by a newer nvime. Relabelling a
-- newer-schema ledger to the current version and rewriting it would drop
-- fields the newer nvime added; instead the caller skips writing so the
-- newer-shaped data is preserved intact.
--
-- Future schema bumps add their forward migrations in M.reconcile where noted.

local M = {}

local warned = {}

-- Reconcile an on-disk ledger's schema version with the running code's
-- `current` version. Returns (version_to_use, is_future):
--   * missing/older/equal version -> (current, false): safe to migrate + write.
--   * newer version               -> (on_disk_version, true): warn once and
--                                     leave untouched; the caller must not
--                                     rewrite it.
function M.reconcile(decoded, current, label)
  local v = tonumber(decoded and decoded.version) or current
  if v > current then
    if not warned[label] then
      warned[label] = true
      vim.schedule(function()
        vim.notify(
          string.format(
            "nvime %s: on-disk schema v%d is newer than this nvime (v%d); leaving it untouched",
            label,
            v,
            current
          ),
          vim.log.levels.WARN
        )
      end)
    end
    return v, true
  end
  -- Older or equal. Forward migrations from prior versions would run here as
  -- the schema grows (e.g. `if v < 2 then ...migrate-v1-to-v2... end`). Only
  -- v1 exists today, so this normalizes the label to the current version.
  return current, false
end

-- Test hook: clear the one-shot warning latches.
function M._reset()
  warned = {}
end

return M
