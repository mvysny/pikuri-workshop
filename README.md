# pikuri-workshop

The power tools for [pikuri](https://github.com/mvysny/pikuri), a small Ruby AI assistant:
a shell, a coding agent, language servers, MCP servers, Agent Skills, durable memory and an
OS assistant, plus what a chat app needs to host many conversations and save them. Each is a
gem you wire à la carte. The tools that run code you didn't write run in a cage, and the book
says what the cage buys and where it stops.

pikuri itself is what you can safely leave lying around the house: no shell, no stranger's
code, nothing that holds all three legs of the lethal trifecta. This is the workshop, and its
tools need care. Read [pikuri's book](https://github.com/mvysny/pikuri/blob/master/book/README.md)
first; [the workshop's](book/README.md) picks up where it ends.

## The gems

| Gem | What it adds |
|---|---|
| [`pikuri-code`](pikuri-code/README.md) | `bash` in a sandbox, and `bin/pikuri-code`, an in-repo coding agent |
| [`pikuri-os`](pikuri-os/README.md) | an offline OS-helper agent with the network cut, `bin/pikuri-os` |
| [`pikuri-lsp`](pikuri-lsp/README.md) | read-only code navigation through a language server |
| [`pikuri-mcp`](pikuri-mcp/README.md) | Model Context Protocol servers, containerised |
| [`pikuri-skills`](pikuri-skills/README.md) | Agent Skills and slash commands |
| [`pikuri-tasks`](pikuri-tasks/README.md) | a per-agent task list for long multi-step work |
| [`pikuri-memory`](pikuri-memory/README.md) | durable cross-conversation memory backed by mem0 |
| [`pikuri-extractors`](pikuri-extractors/README.md) | office, EPUB and RTF documents to Markdown, in a networkless container |
| [`pikuri-stemmers`](pikuri-stemmers/README.md) | keyword search in languages other than English: Finnish |
| [`pikuri-conversations`](pikuri-conversations/README.md) | many live conversations for a chat app, each its own agent on its own threads, saved and resumed |

Each depends on [`pikuri-core`](https://github.com/mvysny/pikuri/blob/master/pikuri-core/README.md),
and some on other pikuri gems; nothing in pikuri depends on the workshop.

## Install

Until the next release, ride both repos from git:

```ruby
git 'https://github.com/mvysny/pikuri.git', branch: 'master' do
  gem 'pikuri-core'
end
git 'https://github.com/mvysny/pikuri-workshop.git', branch: 'master' do
  gem 'pikuri-code'
end
```

To hack on the workshop itself:

```sh
git clone https://github.com/mvysny/pikuri-workshop.git
cd pikuri-workshop
bundle install
bundle exec rake check
```

pikuri comes from its repo at the commit `PIKURI_REF` in the `Gemfile` names. To try an
unpushed pikuri change, point that `git` block at `path: '../pikuri'` for the session, and
put the pin back before you commit.

## License

MIT, see [LICENSE](LICENSE).
