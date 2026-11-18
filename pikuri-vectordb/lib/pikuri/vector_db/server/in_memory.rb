# frozen_string_literal: true

require 'monitor'

module Pikuri
  module VectorDb
    module Server
      # The null supervisor — the in-process implementation of the Server
      # protocol ({.ensure_running} / {#client} / {#close}) that {Qdrant}
      # implements over podman/docker. No container, no process: it owns the
      # {Backend::InMemory} stores' *lifetime* the way the podman/docker supervisors own
      # a *container*, which is what lets +bin/pikuri-corpus+ pick a Server
      # class, call +ensure_running.client(...)+, and close it identically for
      # both engines.
      #
      # +#client(collection:)+ memoizes one store per collection name (same name
      # → same store, so the {Watcher} and agent share one index), guarded by a
      # +Monitor+ so clients mint from any thread. {#close} empties every store
      # and clears the registry — outstanding clients keep working but go
      # *empty*, mirroring the podman/docker servers removing the container under the
      # client's feet (degraded and visible, never silently stale). {#ensure_running!}
      # is a no-op and deliberately does NOT register with {Pikuri::Finalizers} —
      # process exit reclaims RAM, so a no-op teardown would be ceremony.
      class InMemory
        # Construct a server and "ensure it's running" — a no-op
        # for RAM, present so call sites can treat all three Server
        # classes identically
        # (+server_class.ensure_running.client(...)+).
        #
        # @return [InMemory]
        def self.ensure_running(**)
          new.ensure_running!
        end

        # @return [InMemory]
        def initialize
          @collections = {}
          @lock = Monitor.new
        end

        # No-op (nothing to boot); returns self so the
        # +ensure_running.client(...)+ chain works.
        #
        # @return [InMemory]
        def ensure_running!
          self
        end

        # Fetch-or-create the {Backend::InMemory} store for
        # +collection+. Same name → same store; the registry
        # persists until {#close}.
        #
        # @param collection [String] collection name.
        # @return [Backend::InMemory]
        # @raise [ArgumentError] on empty +collection+ (same
        #   contract as the podman/docker servers' backends).
        def client(collection:)
          raise ArgumentError, 'collection must be non-empty' if collection.nil? || collection.to_s.empty?

          @lock.synchronize do
            @collections[collection] ||= Backend::InMemory.new
          end
        end

        # Empty every store and clear the registry. Outstanding
        # clients return no hits afterwards (see the class header).
        # Idempotent; safe to call directly at host teardown.
        #
        # @return [void]
        def close
          @lock.synchronize do
            @collections.each_value(&:delete_all)
            @collections.clear
          end
          nil
        end
      end
    end
  end
end
