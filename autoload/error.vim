vim9script

export enum Error
	InvalidPort("C001"),
	InvalidHost("C002"),
	MissingHost("C003"),
	InvalidExecuteCommand("C004"),
	InvalidOp("C005"),
	RsyncScpUnavailable("C006"),
	InvalidNumberOfArguments("C007"),
	NoOpsSpecified("C008"),
	InvalidSshOption("C009"),
	SshOptionRequiresValue("C010"),
	InvalidTermOption("C011"),
	TermOptionRequiresValue("C012"),
	InvalidConduitOption("C013"),
	InvalidConduitCommand("C014"),
	CouldNotOpenTerm("C015"),
	InvalidOpPathFormat("C016"),
	MissingNotifierOptionKey("C017"),
	Misc("C018")

	const code: string

	def Format(msg: string): string
		return $'{this.Code()}: {msg}'
	enddef

	def Code(): string
		return this.code
	enddef
endenum
