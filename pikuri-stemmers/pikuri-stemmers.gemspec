# frozen_string_literal: true

require_relative '../version'

Gem::Specification.new do |spec|
  spec.name        = 'pikuri-stemmers'
  spec.version     = Pikuri::Workshop::VERSION
  spec.authors     = ['Martin Vysny']
  spec.email       = ['martin@vysny.me']

  spec.summary     = 'Stemmers for pikuri-rag\'s keyword search, one per language: Finnish through Voikko.'
  spec.description = <<~DESC
    pikuri-stemmers plugs languages other than English into
    pikuri-rag's keyword index, as the +stemmer:+ of
    +Pikuri::Rag::Extension+. +Pikuri::Stemmers::Voikko+ stems Finnish
    to dictionary forms and splits compounds, so "katu" finds
    "kadulla" and "kone" finds "tietokoneella".

    Each stemmer takes an open handle of its language library, which
    the host adds and opens itself; this gem requires none of them, so
    a host installs only the languages it uses.
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

  # The Pikuri namespace and Zeitwerk; pinned to the pikuri release this
  # workshop was built against. Not pikuri-rag: a stemmer is a duck it
  # calls, and nothing here names a pikuri-rag constant.
  spec.add_dependency 'pikuri-core', Pikuri::Workshop::PIKURI

  # No language library: each is the host's, injected as an open handle
  # (D_voikko_stemmer). The specs take theirs from the root Gemfile.
end
