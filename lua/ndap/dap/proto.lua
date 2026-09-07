---@meta
---@brief DAP (Debug Adapter Protocol) specification types.

---https://microsoft.github.io/debug-adapter-protocol/specification
---Transcribed from `debugProtocol.json` in microsoft/debug-adapter-protocol
---(MIT): names and types only, none of the spec's own prose.

-- Primitive aliases

assert(false, "should not require() a meta file")

---@alias ndap.dap.proto.SteppingGranularity "statement"|"line"|"instruction"
---@alias ndap.dap.proto.OutputCategory "console"|"important"|"stdout"|"stderr"|"telemetry"|string
---@alias ndap.dap.proto.ChecksumAlgorithm "MD5"|"SHA1"|"SHA256"|"timestamp"
---@alias ndap.dap.proto.DataBreakpointAccessType "read"|"write"|"readWrite"
---@alias ndap.dap.proto.StartMethod "launch"|"attach"|"attachForSuspendedLaunch"
---@alias ndap.dap.proto.SourcePresentationHint "normal"|"emphasize"|"deemphasize"
---@alias ndap.dap.proto.StackFramePresentationHint "normal"|"label"|"subtle"
---@alias ndap.dap.proto.ScopePresentationHint "arguments"|"locals"|"registers"|"returnValue"|string
---@alias ndap.dap.proto.VariablePresentationHintKind "property"|"method"|"class"|"data"|"event"|"baseClass"|"innerClass"|"interface"|"mostDerivedClass"|"virtual"|"dataBreakpoint"|string
---@alias ndap.dap.proto.VariablePresentationHintVisibility "public"|"private"|"protected"|"internal"|"final"
---@alias ndap.dap.proto.DisassembledInstructionPresentationHint "normal"|"invalid"
---@alias ndap.dap.proto.EvaluateContext "watch"|"repl"|"hover"|"clipboard"|"variables"|string
---@alias ndap.dap.proto.CompletionItemType "method"|"function"|"constructor"|"field"|"variable"|"class"|"interface"|"module"|"property"|"unit"|"value"|"enum"|"keyword"|"snippet"|"text"|"color"|"file"|"reference"|"customcolor"
---@alias ndap.dap.proto.InvalidatedAreas "all"|"stacks"|"threads"|"variables"|string
---@alias ndap.dap.proto.ThreadEventReason "started"|"exited"|string
---@alias ndap.dap.proto.BreakpointEventReason "changed"|"new"|"removed"|string
---@alias ndap.dap.proto.ModuleEventReason "new"|"changed"|"removed"
---@alias ndap.dap.proto.LoadedSourceEventReason "new"|"changed"|"removed"
---@alias ndap.dap.proto.BreakpointModeApplicability "source"|"exception"|"data"|"instruction"

-- Base data types

---@class ndap.dap.proto.Checksum
---@field algorithm ndap.dap.proto.ChecksumAlgorithm
---@field checksum  string

---@class ndap.dap.proto.Source
---@field name?             string
---@field path?             string
---@field sourceReference?  integer
---@field presentationHint? ndap.dap.proto.SourcePresentationHint
---@field origin?           string
---@field sources?          ndap.dap.proto.Source[]
---@field adapterData?      any
---@field checksums?        ndap.dap.proto.Checksum[]
---@field id?               integer|string  -- adapter extension: used by some adapters for source correlation

---@class ndap.dap.proto.Thread
---@field id   integer
---@field name string

---@class ndap.dap.proto.StackFrameFormat
---@field hex?             boolean
---@field parameters?      boolean
---@field parameterTypes?  boolean
---@field parameterNames?  boolean
---@field parameterValues? boolean
---@field line?            boolean
---@field module?          boolean
---@field includeAll?      boolean

---@class ndap.dap.proto.StackFrame
---@field id                           integer
---@field name                         string
---@field source?                      ndap.dap.proto.Source
---@field line                         integer
---@field column                       integer
---@field endLine?                     integer
---@field endColumn?                   integer
---@field canRestart?                  boolean
---@field instructionPointerReference? string
---@field moduleId?                    integer|string
---@field presentationHint?            ndap.dap.proto.StackFramePresentationHint

---@class ndap.dap.proto.Scope
---@field name               string
---@field presentationHint?  ndap.dap.proto.ScopePresentationHint
---@field variablesReference integer
---@field namedVariables?    integer
---@field indexedVariables?  integer
---@field expensive          boolean
---@field source?            ndap.dap.proto.Source
---@field line?              integer
---@field column?            integer
---@field endLine?           integer
---@field endColumn?         integer

---@class ndap.dap.proto.VariablePresentationHint
---@field kind?       ndap.dap.proto.VariablePresentationHintKind
---@field attributes? string[]
---@field visibility? ndap.dap.proto.VariablePresentationHintVisibility
---@field lazy?       boolean

---@class ndap.dap.proto.Variable
---@field name                          string
---@field value                         string
---@field type?                         string
---@field presentationHint?             ndap.dap.proto.VariablePresentationHint
---@field evaluateName?                 string
---@field variablesReference            integer
---@field namedVariables?               integer
---@field indexedVariables?             integer
---@field memoryReference?              string
---@field declarationLocationReference? integer
---@field valueLocationReference?       integer

---@class ndap.dap.proto.ValueFormat
---@field hex? boolean

---@class ndap.dap.proto.Module
---@field id             integer|string
---@field name           string
---@field path?          string
---@field isOptimized?   boolean
---@field isUserCode?    boolean
---@field version?       string
---@field symbolStatus?  string
---@field symbolFilePath? string
---@field dateTimeStamp? string
---@field addressRange?  string

---@class ndap.dap.proto.ColumnDescriptor
---@field attributeName  string
---@field label          string
---@field format?        string
---@field type?          "string"|"number"|"boolean"|"unixTimestampUTC"
---@field width?         integer

---@class ndap.dap.proto.CompletionItem
---@field label          string
---@field text?          string
---@field sortText?      string
---@field detail?        string
---@field type?          ndap.dap.proto.CompletionItemType
---@field start?         integer
---@field length?        integer
---@field selectionStart? integer
---@field selectionLength? integer

---@class ndap.dap.proto.ExceptionBreakpointsFilter
---@field filter               string
---@field label                string
---@field description?         string
---@field default?             boolean
---@field supportsCondition?   boolean
---@field conditionDescription? string

---@class ndap.dap.proto.ExceptionOptions
---@field path?     ndap.dap.proto.ExceptionPathSegment[]
---@field breakMode ndap.dap.ExceptionBreakMode

---@class ndap.dap.proto.ExceptionPathSegment
---@field negate? boolean
---@field names   string[]

---@class ndap.dap.proto.ExceptionFilterOptions
---@field filterId   string
---@field condition? string

---@class ndap.dap.proto.ExceptionDetails
---@field message?        string
---@field typeName?       string
---@field fullTypeName?   string
---@field evaluateName?   string
---@field stackTrace?     string
---@field innerException? ndap.dap.proto.ExceptionDetails[]

---@class ndap.dap.proto.BreakpointLocation
---@field line        integer
---@field column?     integer
---@field endLine?    integer
---@field endColumn?  integer

---Adapter response for a single breakpoint (e.g. from setBreakpoints).
---@class ndap.dap.proto.Breakpoint
---@field id?          integer
---@field verified     boolean
---@field message?     string
---@field source?      ndap.dap.proto.Source
---@field line?        integer
---@field column?      integer
---@field endLine?     integer
---@field endColumn?   integer
---@field instructionReference? string
---@field offset?      integer
---@field reason?      string

---Wire-format breakpoint sent in setBreakpoints.
---@class ndap.dap.proto.SourceBreakpoint
---@field line          integer
---@field column?       integer
---@field condition?    string
---@field hitCondition? string
---@field logMessage?   string
---@field mode?         string

---Wire-format breakpoint sent in setFunctionBreakpoints.
---@class ndap.dap.proto.FunctionBreakpoint
---@field name          string
---@field condition?    string
---@field hitCondition? string

---@class ndap.dap.proto.DataBreakpoint
---@field dataId        string
---@field accessType?   ndap.dap.proto.DataBreakpointAccessType
---@field condition?    string
---@field hitCondition? string

---@class ndap.dap.proto.InstructionBreakpoint
---@field instructionReference string
---@field offset?              integer
---@field condition?           string
---@field hitCondition?        string
---@field mode?                string

---@class ndap.dap.proto.BreakpointMode
---@field mode        string
---@field label       string
---@field description? string
---@field appliesTo?  ndap.dap.proto.BreakpointModeApplicability[]

---@class ndap.dap.proto.GotoTarget
---@field id                      integer
---@field label                   string
---@field line                    integer
---@field column?                 integer
---@field endLine?                integer
---@field endColumn?              integer
---@field instructionPointerReference? string

---@class ndap.dap.proto.StepInTarget
---@field id    integer
---@field label string
---@field line?   integer
---@field column? integer
---@field endLine? integer
---@field endColumn? integer

---@class ndap.dap.proto.DisassembledInstruction
---@field address           string
---@field instructionBytes? string
---@field instruction       string
---@field symbol?           string
---@field location?         ndap.dap.proto.Source
---@field line?             integer
---@field column?           integer
---@field endLine?          integer
---@field endColumn?        integer
---@field presentationHint? ndap.dap.proto.DisassembledInstructionPresentationHint

-- Capabilities

---@class ndap.dap.proto.Capabilities
---@field supportsConfigurationDoneRequest?      boolean
---@field supportsFunctionBreakpoints?           boolean
---@field supportsConditionalBreakpoints?        boolean
---@field supportsHitConditionalBreakpoints?     boolean
---@field supportsEvaluateForHovers?             boolean
---@field exceptionBreakpointFilters?            ndap.dap.proto.ExceptionBreakpointsFilter[]
---@field supportsStepBack?                      boolean
---@field supportsSetVariable?                   boolean
---@field supportsRestartFrame?                  boolean
---@field supportsGotoTargetsRequest?            boolean
---@field supportsStepInTargetsRequest?          boolean
---@field supportsCompletionsRequest?            boolean
---@field completionTriggerCharacters?           string[]
---@field supportsModulesRequest?                boolean
---@field additionalModuleColumns?               ndap.dap.proto.ColumnDescriptor[]
---@field supportedChecksumAlgorithms?           ndap.dap.proto.ChecksumAlgorithm[]
---@field supportsRestartRequest?                boolean
---@field supportsExceptionOptions?              boolean
---@field supportsValueFormattingOptions?        boolean
---@field supportsExceptionInfoRequest?          boolean
---@field supportTerminateDebuggee?              boolean
---@field supportSuspendDebuggee?                boolean
---@field supportsDelayedStackTraceLoading?      boolean
---@field supportsLoadedSourcesRequest?          boolean
---@field supportsLogPoints?                     boolean
---@field supportsTerminateThreadsRequest?       boolean
---@field supportsSetExpression?                 boolean
---@field supportsTerminateRequest?              boolean
---@field supportsDataBreakpoints?               boolean
---@field supportsReadMemoryRequest?             boolean
---@field supportsWriteMemoryRequest?            boolean
---@field supportsDisassembleRequest?            boolean
---@field supportsCancelRequest?                 boolean
---@field supportsBreakpointLocationsRequest?    boolean
---@field supportsClipboardContext?              boolean
---@field supportsSteppingGranularity?           boolean
---@field supportsInstructionBreakpoints?        boolean
---@field supportsExceptionFilterOptions?        boolean
---@field supportsSingleThreadExecutionRequests? boolean
---@field supportsDataBreakpointBytes?           boolean
---@field breakpointModes?                       ndap.dap.proto.BreakpointMode[]
---@field supportsANSIStyling?                   boolean
---@field supportsStartDebuggingRequest?         boolean
---@field supportsArgsCanBeInterpretedByShell?   boolean

-- Event bodies

---@class ndap.dap.proto.StoppedEventBody
---@field reason             string
---@field description?       string
---@field threadId?          integer
---@field preserveFocusHint? boolean
---@field text?              string
---@field allThreadsStopped? boolean
---@field hitBreakpointIds?  integer[]

---@class ndap.dap.proto.ContinuedEventBody
---@field threadId             integer
---@field allThreadsContinued? boolean

---@class ndap.dap.proto.ExitedEventBody
---@field exitCode integer

---@class ndap.dap.proto.TerminatedEventBody
---@field restart? any

---@class ndap.dap.proto.ThreadEventBody
---@field threadId integer
---@field reason   ndap.dap.proto.ThreadEventReason

---@class ndap.dap.proto.OutputEventBody
---@field category?           ndap.dap.proto.OutputCategory
---@field output              string
---@field group?              "start"|"startCollapsed"|"end"
---@field variablesReference? integer
---@field source?             ndap.dap.proto.Source
---@field line?               integer
---@field column?             integer
---@field data?               any

---@class ndap.dap.proto.BreakpointEventBody
---@field reason     ndap.dap.proto.BreakpointEventReason
---@field breakpoint ndap.dap.proto.Breakpoint

---@class ndap.dap.proto.ModuleEventBody
---@field reason ndap.dap.proto.ModuleEventReason
---@field module ndap.dap.proto.Module

---@class ndap.dap.proto.LoadedSourceEventBody
---@field reason ndap.dap.proto.LoadedSourceEventReason
---@field source ndap.dap.proto.Source

---@class ndap.dap.proto.ProcessEventBody
---@field name             string
---@field systemProcessId? integer
---@field isLocalProcess?  boolean
---@field startMethod?     ndap.dap.proto.StartMethod
---@field pointerSize?     integer

---@class ndap.dap.proto.CapabilitiesEventBody
---@field capabilities ndap.dap.proto.Capabilities

---@class ndap.dap.proto.ProgressStartEventBody
---@field progressId  string
---@field title       string
---@field requestId?  integer
---@field cancellable? boolean
---@field message?    string
---@field percentage? number

---@class ndap.dap.proto.ProgressUpdateEventBody
---@field progressId string
---@field message?   string
---@field percentage? number

---@class ndap.dap.proto.ProgressEndEventBody
---@field progressId string
---@field message?   string

---@class ndap.dap.proto.InvalidatedEventBody
---@field areas?    ndap.dap.proto.InvalidatedAreas[]
---@field threadId? integer
---@field stackFrameId? integer

---@class ndap.dap.proto.MemoryEventBody
---@field memoryReference string
---@field offset          integer
---@field count           integer

-- Request arguments

---@class ndap.dap.proto.InitializeRequestArguments
---@field clientID?                            string
---@field clientName?                          string
---@field adapterID                            string
---@field locale?                              string
---@field linesStartAt1?                       boolean
---@field columnsStartAt1?                     boolean
---@field pathFormat?                          "path"|"uri"|string
---@field supportsVariableType?                boolean
---@field supportsVariablePaging?              boolean
---@field supportsRunInTerminalRequest?        boolean
---@field supportsMemoryReferences?            boolean
---@field supportsProgressReporting?           boolean
---@field supportsInvalidatedEvent?            boolean
---@field supportsMemoryEvent?                 boolean
---@field supportsArgsCanBeInterpretedByShell? boolean
---@field supportsStartDebuggingRequest?       boolean
---@field supportsANSIStyling?                 boolean

---@class ndap.dap.proto.ConfigurationDoneArguments

---@class ndap.dap.proto.LaunchRequestArguments
---@field noDebug?  boolean
---@field restart?  any
---[any adapter-specific keys]

---@class ndap.dap.proto.AttachRequestArguments
---@field restart?  any
---[any adapter-specific keys]

---@class ndap.dap.proto.RestartArguments
---@field arguments? ndap.dap.proto.LaunchRequestArguments|ndap.dap.proto.AttachRequestArguments

---@class ndap.dap.proto.DisconnectArguments
---@field restart?           boolean
---@field terminateDebuggee? boolean
---@field suspendDebuggee?   boolean

---@class ndap.dap.proto.TerminateArguments
---@field restart? boolean

---@class ndap.dap.proto.BreakpointLocationsArguments
---@field source    ndap.dap.proto.Source
---@field line      integer
---@field column?   integer
---@field endLine?  integer
---@field endColumn? integer

---@class ndap.dap.proto.SetBreakpointsArguments
---@field source          ndap.dap.proto.Source
---@field breakpoints?    ndap.dap.proto.SourceBreakpoint[]
---@field lines?          integer[]
---@field sourceModified? boolean

---@class ndap.dap.proto.SetFunctionBreakpointsArguments
---@field breakpoints ndap.dap.proto.FunctionBreakpoint[]

---@class ndap.dap.proto.SetExceptionBreakpointsArguments
---@field filters          string[]
---@field filterOptions?   ndap.dap.proto.ExceptionFilterOptions[]
---@field exceptionOptions? ndap.dap.proto.ExceptionOptions[]

---@class ndap.dap.proto.DataBreakpointInfoArguments
---@field variablesReference? integer
---@field name                string
---@field frameId?            integer
---@field bytes?              integer
---@field asAddress?          boolean
---@field mode?               string

---@class ndap.dap.proto.SetDataBreakpointsArguments
---@field breakpoints ndap.dap.proto.DataBreakpoint[]

---@class ndap.dap.proto.SetInstructionBreakpointsArguments
---@field breakpoints ndap.dap.proto.InstructionBreakpoint[]

-- For the execution-control requests below, `threadId` is required on the wire
-- but optional here: the ndap Session methods fill it from the active thread
-- when omitted (see session.lua).

---@class ndap.dap.proto.ContinueArguments
---@field threadId?     integer
---@field singleThread? boolean

---@class ndap.dap.proto.NextArguments
---@field threadId?     integer
---@field singleThread? boolean
---@field granularity?  ndap.dap.proto.SteppingGranularity

---@class ndap.dap.proto.StepInArguments
---@field threadId?     integer
---@field singleThread? boolean
---@field targetId?     integer
---@field granularity?  ndap.dap.proto.SteppingGranularity

---@class ndap.dap.proto.StepOutArguments
---@field threadId?     integer
---@field singleThread? boolean
---@field granularity?  ndap.dap.proto.SteppingGranularity

---@class ndap.dap.proto.StepBackArguments
---@field threadId?     integer
---@field singleThread? boolean
---@field granularity?  ndap.dap.proto.SteppingGranularity

---@class ndap.dap.proto.ReverseContinueArguments
---@field threadId?     integer
---@field singleThread? boolean

---@class ndap.dap.proto.GotoArguments
---@field threadId? integer
---@field targetId  integer

---@class ndap.dap.proto.RestartFrameArguments
---@field frameId integer

---@class ndap.dap.proto.PauseArguments
---@field threadId? integer

---@class ndap.dap.proto.StackTraceArguments
---@field threadId    integer
---@field startFrame? integer
---@field levels?     integer
---@field format?     ndap.dap.proto.StackFrameFormat

---@class ndap.dap.proto.ScopesArguments
---@field frameId integer

---@class ndap.dap.proto.VariablesArguments
---@field variablesReference integer
---@field filter?            "indexed"|"named"
---@field start?             integer
---@field count?             integer
---@field format?            ndap.dap.proto.ValueFormat

---@class ndap.dap.proto.SetVariableArguments
---@field variablesReference integer
---@field name               string
---@field value              string
---@field format?            ndap.dap.proto.ValueFormat

---@class ndap.dap.proto.SourceArguments
---@field source?          ndap.dap.proto.Source
---@field sourceReference  integer

---@class ndap.dap.proto.TerminateThreadsArguments
---@field threadIds? integer[]

---@class ndap.dap.proto.ModulesArguments
---@field startModule? integer
---@field moduleCount? integer

---@class ndap.dap.proto.EvaluateArguments
---@field expression string
---@field frameId?   integer
---@field context?   ndap.dap.proto.EvaluateContext
---@field format?    ndap.dap.proto.ValueFormat

---@class ndap.dap.proto.SetExpressionArguments
---@field expression string
---@field value      string
---@field frameId?   integer
---@field format?    ndap.dap.proto.ValueFormat

---@class ndap.dap.proto.StepInTargetsArguments
---@field frameId integer

---@class ndap.dap.proto.GotoTargetsArguments
---@field source  ndap.dap.proto.Source
---@field line    integer
---@field column? integer

---@class ndap.dap.proto.CompletionsArguments
---@field frameId? integer
---@field text     string
---@field column   integer
---@field line?    integer

---@class ndap.dap.proto.ExceptionInfoArguments
---@field threadId? integer  -- required on the wire; ndap defaults it to the active thread

---@class ndap.dap.proto.ReadMemoryArguments
---@field memoryReference string
---@field offset?         integer
---@field count           integer

---@class ndap.dap.proto.WriteMemoryArguments
---@field memoryReference string
---@field offset?         integer
---@field allowPartial?   boolean
---@field data            string

---@class ndap.dap.proto.DisassembleArguments
---@field memoryReference       string
---@field offset?               integer
---@field instructionOffset?    integer
---@field instructionCount      integer
---@field resolveSymbols?       boolean

---@class ndap.dap.proto.CancelArguments
---@field requestId?  integer
---@field progressId? string

-- Response bodies

---@class ndap.dap.proto.BreakpointLocationsResponseBody
---@field breakpoints ndap.dap.proto.BreakpointLocation[]

---@class ndap.dap.proto.SetBreakpointsResponseBody
---@field breakpoints ndap.dap.proto.Breakpoint[]

---@class ndap.dap.proto.SetFunctionBreakpointsResponseBody
---@field breakpoints ndap.dap.proto.Breakpoint[]

---@class ndap.dap.proto.SetExceptionBreakpointsResponseBody
---@field breakpoints? ndap.dap.proto.Breakpoint[]

---@class ndap.dap.proto.DataBreakpointInfoResponseBody
---@field dataId      string|nil
---@field description string
---@field accessTypes? ndap.dap.proto.DataBreakpointAccessType[]
---@field canPersist?  boolean

---@class ndap.dap.proto.SetDataBreakpointsResponseBody
---@field breakpoints ndap.dap.proto.Breakpoint[]

---@class ndap.dap.proto.SetInstructionBreakpointsResponseBody
---@field breakpoints ndap.dap.proto.Breakpoint[]

---@class ndap.dap.proto.ContinueResponseBody
---@field allThreadsContinued? boolean

---@class ndap.dap.proto.StackTraceResponseBody
---@field stackFrames  ndap.dap.proto.StackFrame[]
---@field totalFrames? integer

---@class ndap.dap.proto.ScopesResponseBody
---@field scopes ndap.dap.proto.Scope[]

---@class ndap.dap.proto.VariablesResponseBody
---@field variables ndap.dap.proto.Variable[]

---@class ndap.dap.proto.SetVariableResponseBody
---@field value               string
---@field type?               string
---@field variablesReference? integer
---@field namedVariables?     integer
---@field indexedVariables?   integer
---@field memoryReference?    string
---@field valueLocationReference? integer

---@class ndap.dap.proto.SourceResponseBody
---@field content  string
---@field mimeType? string

---@class ndap.dap.proto.ThreadsResponseBody
---@field threads ndap.dap.proto.Thread[]

---@class ndap.dap.proto.TerminateThreadsResponseBody

---@class ndap.dap.proto.ModulesResponseBody
---@field modules       ndap.dap.proto.Module[]
---@field totalModules? integer

---@class ndap.dap.proto.LoadedSourcesResponseBody
---@field sources ndap.dap.proto.Source[]

---@class ndap.dap.proto.EvaluateResponseBody
---@field result                        string
---@field type?                         string
---@field presentationHint?             ndap.dap.proto.VariablePresentationHint
---@field variablesReference            integer
---@field namedVariables?               integer
---@field indexedVariables?             integer
---@field memoryReference?              string
---@field valueLocationReference?       integer
---@field declarationLocationReference? integer

---@class ndap.dap.proto.SetExpressionResponseBody
---@field value               string
---@field type?               string
---@field presentationHint?   ndap.dap.proto.VariablePresentationHint
---@field variablesReference? integer
---@field namedVariables?     integer
---@field indexedVariables?   integer
---@field memoryReference?    string
---@field valueLocationReference? integer

---@class ndap.dap.proto.StepInTargetsResponseBody
---@field targets ndap.dap.proto.StepInTarget[]

---@class ndap.dap.proto.GotoTargetsResponseBody
---@field targets ndap.dap.proto.GotoTarget[]

---@class ndap.dap.proto.CompletionsResponseBody
---@field targets ndap.dap.proto.CompletionItem[]

---@class ndap.dap.proto.ExceptionInfoResponseBody
---@field exceptionId  string
---@field description? string
---@field breakMode    ndap.dap.ExceptionBreakMode
---@field details?     ndap.dap.proto.ExceptionDetails

---@class ndap.dap.proto.ReadMemoryResponseBody
---@field address          string
---@field unreadableBytes? integer
---@field data?            string

---@class ndap.dap.proto.WriteMemoryResponseBody
---@field offset?         integer
---@field bytesWritten?   integer

---@class ndap.dap.proto.DisassembleResponseBody
---@field instructions ndap.dap.proto.DisassembledInstruction[]

-- Adapter-initiated request args / response bodies

---@class ndap.dap.proto.RunInTerminalRequestArguments
---@field kind?   "integrated"|"external"
---@field title?  string
---@field cwd     string
---@field args    string[]
---@field env?    table<string, string>  -- spec allows string|null (null = unset), but we only support string values
---@field argsCanBeInterpretedByShell? boolean

---@class ndap.dap.proto.RunInTerminalResponseBody
---@field processId?      integer
---@field shellProcessId? integer

---@class ndap.dap.proto.StartDebuggingRequestArguments
---@field configuration table<string, any>
---@field request       "launch"|"attach"

return {}
