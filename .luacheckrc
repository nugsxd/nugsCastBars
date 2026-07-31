std = "lua51"
max_line_length = false

-- Written on purpose: these are the addon's SavedVariables, which have to be globals.
globals = {
    "SLASH_%w+",
    "%w*DB$",
    "%w*CharDB$",
}

ignore = {
    "113",  -- accessing an undefined global: every Blizzard API call
    "212",  -- unused argument: event handlers take a fixed signature
    "542",  -- empty if branch: used for readable "do nothing when" cases
}

exclude_files = { ".luacheckrc" }
