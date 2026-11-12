# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-memory gem. Appends the gem's +prompts/+ to
# +Pikuri::PROMPT_DIRS+ (so +Pikuri.prompt(:'memory-extraction')+
# resolves) and sets up the per-gem Zeitwerk loader.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  # Namespace for the durable cross-conversation memory feature: durable
  # memory backed by a self-hosted mem0 server. {Extension} is the
  # host-facing wiring; {Mem0Client} the REST client; {Mem0Server} the
  # optional self-managed stack; {Recorder} the async capture queue;
  # {Record} the row value type; {Recall} the +recall+ tool. mem0 owns
  # extraction, embedding, and resolution.
  #
  # == Three retrieval tiers (the layered shape)
  #
  # 1. **Resident persona** — a small always-in-prompt summary
  #    ({Extension#system_prompt_snippets}), re-pulled on every
  #    {Pikuri::Agent#clear_conversation}.
  # 2. **Automatic prefetch** — {Extension#on_user_message} searches mem0
  #    with the latest user message and returns a high-precision slice as a
  #    +<memory-context>+ block, which
  #    {Pikuri::Agent#append_reference_block} appends.
  # 3. **Explicit deepening** — the +recall+ tool.
  #
  # The same resident-vs-triggered split as +pikuri-vectordb+'s
  # +vectordb_search+/+vectordb_read+ — one mental model across memory and
  # RAG. See design/architecture.md §"The three retrieval tiers".
  #
  # == Safety posture (v1)
  #
  # Automatic capture + recall are safe only on an agent with no untrusted
  # ingest and no egress (the +@private+ configuration): a poisoned memory
  # + an egress leg is the lethal trifecta. The recall→re-extraction
  # feedback loop cannot form because **capture is fed the dispatch
  # argument, never the conversation**: {Extension#on_user_message} hands
  # {Recorder#enqueue} exactly the incoming message, and {Mem0Client#add}
  # wraps that one string. Do not re-derive extraction input from
  # +Chat#messages+ — a recalled block is itself a +:user+ message there
  # (see {Pikuri::Agent#append_reference_block}), so reading the log is
  # what would close the loop. Porting onto an egress-capable agent
  # re-opens recall-poisoning.
  module Memory
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-memory'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(File.expand_path('pikuri-memory.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end
