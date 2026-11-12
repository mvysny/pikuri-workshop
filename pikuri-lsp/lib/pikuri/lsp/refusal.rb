# frozen_string_literal: true

module Pikuri
  module Lsp
    # A model-facing decline: the tool will not answer this call, and the message
    # is the sentence the model reads.
    #
    #   raise Refusal, "no language server is configured for .md files"
    #
    # Raised deep — routing, the capability gate, an anchor that resolves
    # nowhere — and caught once, in {Navigator#navigate}, which prefixes
    # +"Error: "+.
    #
    # It carries no code and no category, deliberately. The three answers a caller
    # must be able to tell apart — *unsupported*, *the server answered nothing*,
    # *the server could not be asked* — stay apart because each has its own
    # sentence, not because a consumer switches on a symbol; collapsing them into
    # one "nothing found, this may be because…" is the defect in the shipped prior
    # art. And a refusal never proposes what to do instead: what failed is a fact,
    # what to try next is the model's call on evidence this tool does not have.
    class Refusal < StandardError; end
  end
end
