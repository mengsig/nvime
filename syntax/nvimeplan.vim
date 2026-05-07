if exists("b:current_syntax")
  finish
endif

syntax match NvimePlanHeading /^\s\{2,4\}\u[A-Z _-]\+$/
syntax match NvimePlanRule /^[─━═]\{8,}$/
syntax match NvimePlanRule /^\s*[─━═]\{8,}$/
syntax match NvimePlanBadgeKey /\[[a-z0-9_.-]\+\]/
syntax match NvimePlanStepDone /^\s*✓.*$/
syntax match NvimePlanStepProgress /^\s*●.*$/
syntax match NvimePlanStepBlocked /^\s*✕.*$/
syntax match NvimePlanStepPending /^\s*○.*$/
syntax match NvimePlanMeta /^\s\{6,\}\(file\|range\|deps\|tests\|notes\):/
syntax match NvimePlanFooter /^\s\+<CR>.*$/

highlight default link NvimePlanHeading Title
highlight default link NvimePlanRule Comment
highlight default link NvimePlanBadgeKey Special
highlight default link NvimePlanStepDone DiffAdd
highlight default link NvimePlanStepProgress Identifier
highlight default link NvimePlanStepBlocked WarningMsg
highlight default link NvimePlanStepPending Comment
highlight default link NvimePlanMeta Comment
highlight default link NvimePlanFooter Comment

let b:current_syntax = "nvimeplan"
