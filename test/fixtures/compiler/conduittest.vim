if exists("current_compiler")
	finish
endif
let current_compiler = "conduittest"

if exists(":CompilerSet") != 2
	command -nargs=* CompilerSet setlocal <args>
endif

CompilerSet errorformat=FIXTURE:%f:%l:%m
