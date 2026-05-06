std = "lua51"

globals = {
  "vim",
}

ignore = {
  "211", -- unused values are still being cleaned up in older modules.
  "311",
  "411",
  "421",
  "431",
  "432",
  "512",
  "542",
  "631", -- max line length is handled by stylua.
}

files["tests/headless_spec.lua"] = {
  ignore = {
    "111", -- large integration spec intentionally keeps many locals.
    "113",
    "211",
    "212",
    "631",
  },
}
