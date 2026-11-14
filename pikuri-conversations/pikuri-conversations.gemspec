# frozen_string_literal: true

require_relative '../version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-conversations'
  spec.version     = Pikuri::Workshop::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Host, store, list and resume pikuri conversations.'
  spec.description = <<~DESC
    pikuri-conversations is the hosting half pikuri leaves to its hosts.
    +Pikuri::Conversations+ runs many live conversations, an agent each,
    its turns on threads of its own, with mid-turn messages, cancel and
    model switches handled from any thread.
    +Pikuri::Conversations::HistoryFile+ is the stored format of a
    +Pikuri::Agent::History+ (pikuri keeps it in memory only), validating
    stored bytes on the way back in and confining attachments to the
    conversation's folder. +Pikuri::Conversations::Store+ keeps one folder
    per conversation, with a +meta.json+ envelope for the title,
    timestamps and the connection it ran on.
  DESC

  spec.homepage = 'https://github.com/mvysny/pikuri-workshop'
  spec.license  = 'MIT'

  spec.required_ruby_version = '>= 3.3'

  spec.metadata = {
    'source_code_uri'       => "#{spec.homepage}/tree/master",
    'changelog_uri'         => "#{spec.homepage}/blob/master/CHANGELOG.md",
    'bug_tracker_uri'       => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir[
    'lib/**/*.rb',
    'LICENSE',
    'README.md'
  ]
  spec.require_paths = ['lib']

  # Agent::History and Attachment, the values the format stores, live in
  # pikuri-core; pinned to the pikuri release this workshop was built against.
  spec.add_dependency 'pikuri-core', Pikuri::Workshop::PIKURI
end
