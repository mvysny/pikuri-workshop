# Containers: Podman, or rootless Docker

From here on, several chapters run somebody else's server in a container: the vector store in
[the next chapter](vectordb.md), mem0's stack in [Memories](memories.md), the MCP servers from
[Your first MCP server](mcp.md) on, and the document converters behind `pikuri-extractors`.
pikuri starts and stops each one for you, with `podman` when it's on your `PATH` and `docker`
otherwise. It doesn't care how the runtime behind that command runs. But *you* should, and
that's this short chapter.

## Meet containers (the sixty-second version)

A **container** runs a program in its own little world: its own filesystem, its own process
table, its own view of the network, all walled off from your real machine unless you
explicitly punch a hole. The program inside thinks it has a whole Linux box; in reality it
can't see your files, your other processes, or your keys. Most server software ships as a
container image now, so it's worth having a runtime installed regardless.

This book uses the box for two different jobs, and it's worth telling them apart:

- **Packaging.** Qdrant and mem0 are servers pikuri didn't write and doesn't want you to
  install by hand. The container is the convenient way to run one pinned version, with its
  data in a folder of yours. Nothing about it is a defense.
- **A cage.** An MCP server or a document converter runs code you didn't write, on input you
  didn't write either. There the box *is* the defense, and what it can reach (the network
  above all) is the point. Those chapters narrow it and measure it.

That's the whole mental model you need. It's a box, the program runs in the box, the box can't
see your stuff unless you say so.

## Podman: the short path

```sh
sudo apt install podman
```

That's it. Podman runs containers as *your* user, with no daemon and no root anywhere in the
chain, so a container, or anything that can start one, reaches at most what your account can
already reach. Same images as Docker, mostly the same command line. Verify:

```sh
podman run --rm docker.io/library/hello-world
```

It pulls a small image and prints *"Hello from Docker!"*, which is the image's text, not a
sign that Docker ran.

## Docker, if you already have it

The setup you'll find in most tutorials is:

```sh
sudo apt install docker.io
sudo usermod -aG docker "$USER"      # ← DON'T DO THIS!!!
```

That second line is **passwordless root** in a trenchcoat. The default Docker daemon runs as
root, and the `docker` group is nothing more than permission to talk to it, so anything
running as your user can ask the root daemon for the keys:

```sh
docker run --rm -v /:/host debian cat /host/etc/shadow
```

No exploit, no CVE: that's the daemon working as designed. And "anything running as your user"
is not just you at the keyboard. A malicious npm postinstall script, a compromised pip
package, one bad `curl | bash`, the very MCP server you were about to box in: anything that
runs as you inherits the group, and "my user account got compromised" silently upgrades to
"root got compromised". For a book whose cages are meant to bound what a stranger's code can
reach, wiring that in as step zero would be absurd.

If you want Docker anyway, run it **rootless**: the daemon itself runs as your user inside a
user namespace, with the same reach Podman has. On Ubuntu 26.04 with the distro package (these
steps are pikuri's book's, and this book didn't re-run them):

```sh
sudo apt install docker.io docker-compose-v2 rootlesskit slirp4netns uidmap
# don't run the system-wide root daemon at all — we won't use it
sudo systemctl disable --now docker.service docker.socket

# set up the per-user daemon (the script ships with docker.io)
/usr/share/docker.io/contrib/dockerd-rootless-setuptool.sh install

# point the docker CLI at your user's daemon socket, persistently
docker context create rootless --docker "host=unix:///run/user/$(id -u)/docker.sock"
docker context use rootless
```

Then, in a fresh shell, `docker info --format '{{.SecurityOptions}}'` should include
`name=rootless`. (A stray `DOCKER_HOST` environment variable overrides the context; unset it if
you had one.) If anything balks, the long-form walkthrough with troubleshooting is
[*Rootless Docker*](https://mvysny.github.io/docker-rootless/). Logging out stops your user's
services, the rootless daemon included; that's irrelevant here, since pikuri starts and stops
its containers with the agent.

Already running the rootful daemon with the `docker` group and not inclined to redo it? The
packaging chapters still work: pikuri talks to whatever `docker` on `PATH` talks to, when
there's no `podman`. The cages are another matter. Their whole claim is that a breakout lands
in your account, bad but not root, and with a root daemon one hop away it doesn't. The rootless
choice protects *you*, not pikuri; reread the `usermod` paragraph and make it deliberately.

## What's next

With a runtime in place, [the vector-DB chapter](vectordb.md) starts its first container:
Qdrant, keeping an index of your documents on disk so you pay the embedding bill once.

→ Continue to [Searching by meaning: the vector DB](vectordb.md).
