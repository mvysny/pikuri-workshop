# frozen_string_literal: true

require 'pikuri-core'

module Pikuri
  # Hosting many conversations, the part pikuri leaves to its hosts: an
  # {Pikuri::Agent} is one synchronous conversation that pikuri never writes
  # to disk, and a chat app needs them stored, listed and resumed.
  #
  #   store = Pikuri::Conversations::Store.new(root: dir, shell: 'my-chat')
  #   entry = store.create
  #   store.save(entry, agent.export_history, model: m, server: s)
  #   agent = Pikuri::Agent.new(transport: t, system_prompt: p, history: store.history(entry))
  #
  # {HistoryFile} is the stored format of an {Pikuri::Agent::History};
  # {Store} keeps one folder per conversation in it.
  #
  # A class rather than a module because it will be the list of live
  # conversations itself — an agent per conversation, its turns on a thread
  # pool. That half is not built yet; the class has no instances until it
  # is.
  class Conversations
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-conversations'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(__FILE__)
    LOADER.setup
    LOADER.eager_load

    private_class_method :new
  end
end
