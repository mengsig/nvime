if exists("b:current_syntax")
  finish
endif

syntax match NvimeTitle /^nvime.*$/
syntax match NvimeTitle /^NVIME.*$/
syntax match NvimeStatus /^provider .*cwd .*$/
syntax match NvimeStatus /^provider .*| read-only conversation.*$/
syntax match NvimeKeys /^enter\/i\/o .*$/
syntax match NvimeKeys /^selection ask\/edit .*$/
syntax match NvimeSeparator /^[=-]\{8,}$/
syntax match NvimePrompt /^\[[^]]*\]\$/
syntax match NvimeExit /^\[nvime\].*$/
syntax match NvimeHeading /^#\+ .*$/
syntax match NvimeBullet /^\s*[-*] .*$/
syntax match NvimeCodeFence /^```.*$/
syntax match NvimeDiffAdd /^+.*$/
syntax match NvimeDiffDelete /^-.*$/
syntax match NvimeDiffHunk /^@@.*$/
syntax match NvimeAgent /^\[\(claude\|codex\).*response\]$/

highlight default link NvimeTitle Title
highlight default link NvimeStatus StatusLine
highlight default link NvimeKeys Comment
highlight default link NvimeSeparator Comment
highlight default link NvimePrompt Statement
highlight default link NvimeExit Comment
highlight default link NvimeAgent Identifier
highlight default link NvimeHeading Title
highlight default link NvimeBullet Special
highlight default link NvimeCodeFence PreProc
highlight default link NvimeDiffAdd DiffAdd
highlight default link NvimeDiffDelete DiffDelete
highlight default link NvimeDiffHunk DiffChange
highlight default link NvimeConflict WarningMsg

let b:current_syntax = "nvime"
