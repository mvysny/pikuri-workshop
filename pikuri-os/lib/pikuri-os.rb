# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-workspace'
require 'pikuri-code'

# Entry file for the pikuri-os gem: the OS-integration layer and home of
# the +bin/pikuri-os+ demo — a single, local, network-severed
# agent for understanding and operating the host OS ({Pikuri::Os::Extension}
# is the one-call wiring). The load-bearing posture: egress severed at the
# kernel (a net-isolated Bash sandbox), every mutation confirmed, durable
# memory a user-owned +MACHINE.md+ rather than mem0 — so this gem depends
# on pikuri-code but NOT pikuri-mcp/-memory/-vectordb. The two cross-cutting
# pieces (+FullFsNoNet+ sandbox, passive-command detector) live in
# pikuri-code with the other OS-touching primitives. Design notes:
# +pikuri-os/design/architecture.md+ (the file-index engine survey) and
# book/os-assistant.md (the security narrative).
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  module Os
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-os'
    LOADER.push_dir(__dir__)
    LOADER.ignore(File.expand_path('pikuri-os.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end
