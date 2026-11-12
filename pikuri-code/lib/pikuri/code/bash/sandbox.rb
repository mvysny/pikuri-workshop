# frozen_string_literal: true

require 'fileutils'
require 'pathname'
require 'set'

module Pikuri
  module Code
    class Bash
      # Filesystem-sandbox seam for the bash tool. A sandbox responds to
      # +#wrap(argv) → Array<String>+, transforming the +timeout … bash -c
      # <cmd>+ argv {Bash.run} would spawn into the argv actually spawned:
      # {NONE} returns it unchanged (the default), {Bubblewrap} prepends
      # +bwrap+ + bind/isolation flags, {FullFsNoNet} is Bubblewrap's inverse.
      #
      # Distinct from Workspace, deliberately: Workspace is "what the LLM
      # observes via Read/Write/Edit/Grep/Glob"; Sandbox is "what the executed
      # subprocess sees." They overlap on project + toolchain dirs but diverge
      # on the OS-runtime baseline ({Bubblewrap::ETC_BASELINE} — TLS certs,
      # DNS, tz, hosts): the LLM has no need to {Read} +/etc/resolv.conf+, the
      # +curl+ subprocess does. Separate objects keep each allowlist with its
      # owner.
      #
      # The full two-sandbox design — each posture's threat model, the
      # overlay/concurrency reasoning, and which to pick — is in
      # +pikuri-code/design/architecture.md+.
      #
      # == Posture predicates
      #
      # A sandbox also answers two questions about itself, which is how {Bash}
      # computes its {Pikuri::Tool::TrifectaLegs} — asking the object rather
      # than reading a flag out of the argv, because the argv is exactly where
      # that reading goes wrong:
      #
      # * +#egress?+ — can the wrapped command reach a network sink?
      # * +#confined_to_workspace?+ — does it see only the workspace?
      #
      # Both are **conservative at the identity element**: {NONE} answers
      # +true+/+false+ respectively, so a host that subclasses one of these
      # (the {Bubblewrap} header invites it) inherits an answer that is wrong
      # only in the safe direction. A sandbox that could ever *degrade* to a
      # networked run rather than raising must answer +egress? == true+, and a
      # severed network namespace alone is not evidence of a severed leg — a
      # reachable session bus spawns the fetch outside every namespace (see
      # {FullFsNoNet::SESSION_IPC_MASKS}).
      module Sandbox
        # The +bwrap+(1) binary, resolved on +PATH+.
        BWRAP_BINARY = 'bwrap'

        # Run a one-shot +bwrap+ probe and return the finished process: spawns
        # +bwrap <flags> --die-with-parent /bin/true+ at +/+ and waits.
        #
        #   Sandbox.probe('--bind', '/', '/', '--unshare-net').status.success?
        #
        # +flags+ are the isolation each sandbox promises (+--unshare-net+, an
        # overlay mount, …) — deliberately *not* defaulted, because the probe's
        # whole job is to prove *that exact* isolation works on this host (see
        # +pikuri-code/design/architecture.md+ on why the two probes aren't interchangeable).
        # Propagates +Errno::ENOENT+ when +bwrap+ is absent; each caller rescues
        # it to raise its own install hint.
        #
        # @param flags [Array<String>] isolation flags under test.
        # @return [Pikuri::Subprocess::Result] query +.status.success?+ /
        #   +.status.exitstatus+.
        # @raise [Errno::ENOENT] if +bwrap+ isn't on +PATH+.
        def self.probe(*flags)
          Pikuri::Subprocess.spawn(
            BWRAP_BINARY, *flags, '--die-with-parent', '/bin/true', chdir: '/'
          ).wait
        end

        # Identity sandbox — passthrough. The {Bash.new} default and the
        # +--no-sandbox+ / +--yolo+ opt-out.
        module NONE
          # @param argv [Array<String>]
          # @return [Array<String>] argv unchanged
          def self.wrap(argv)
            argv
          end

          # @return [Boolean] +true+ — an unwrapped command has the host's
          #   network
          def self.egress? = true

          # @return [Boolean] +false+ — an unwrapped command has the host's
          #   whole filesystem, whatever the workspace was scoped to
          def self.confined_to_workspace? = false
        end

        # Bubblewrap (+bwrap+(1)) filesystem sandbox for the bash subprocess:
        # composes a +bwrap+ argv from the supplied {Workspace} plus a curated
        # OS-runtime baseline, so the subprocess sees only project + toolchain +
        # ephemeral temp + the few +/etc+ files needed for TLS/DNS/tz/hostname.
        # Keeps the network (+--share-net+); contains the filesystem. Its
        # inverse is {FullFsNoNet}. Full posture comparison + threat model in
        # +pikuri-code/design/architecture.md+.
        #
        # == What's bound
        #
        # * {SYSTEM_ROOTS} (+/lib+ +/lib64+ +/bin+ +/sbin+) and {ETC_BASELINE}
        #   — +--ro-bind+. Not in {Workspace#readable} (the LLM has no business
        #   grepping +/sbin+), but the subprocess needs them for the dynamic
        #   linker, standard utilities, and the TLS/DNS/tz/hostname handshake.
        #   +/usr+ and +/opt+ arrive via {Workspace#readable} instead (added by
        #   {Pikuri::Code::ToolchainPaths.readable}).
        # * +/tmp+ — bound to {Workspace::Filesystem#temp} when set (so the
        #   LLM's reflexive +/tmp+ writes persist across bash calls), else
        #   +--tmpfs+. The host's +/tmp+ is never exposed. Synthetic +/proc+
        #   (+--unshare-pid+) and +/dev+ (null/zero/random/tty) round it out.
        # * +workspace.writable+ — +--bind+ (read+write, *persistent*).
        # * +workspace.readable+ — read-write *ephemeral overlay* (host dir the
        #   read-through lower, a per-session upper under
        #   +<internal_temp>/overlay-<slug>/+ absorbs writes), so +gem install+
        #   / +bundle+ / +mvn+ / +gradle+ / +cargo+ / +pip+ succeed while the
        #   host toolchain stays untouched. Falls back to +--ro-bind+ without
        #   overlayfs-in-userns (Linux < 5.11), in which case a write into a
        #   read-only toolchain dir fails +EROFS+ (surfaced as the bash
        #   observation); this degrades with a logged warning, never raises.
        #   Why the mounts are narrow cache subdirs (secrets stay out of the
        #   sandbox's *view*): {Pikuri::Code::ToolchainPaths}. Warm-cache
        #   lifetime + the +EBUSY+ concurrency argument: +pikuri-code/design/architecture.md+.
        #
        # == Isolation
        #
        # +--unshare-all --share-net+: PID/mount/IPC/user/UTS unshared (can't
        # see host processes, mount on the host, or ptrace); the network is
        # *kept* shared because bash routinely needs +git pull+/+mvn+/+gem
        # install+/+curl+. +--die-with-parent --new-session+: dies with pikuri,
        # own session group (no terminal-control bleed).
        #
        # Blast-radius containment, *not* a malware boundary — the non-defenses
        # (project source, poisoned deps, network exfil) and the container-as-
        # outer-boundary escape hatch are in +pikuri-code/design/architecture.md+.
        class Bubblewrap
          LOGGER = Pikuri.logger_for('Sandbox')

          # System-root dirs the subprocess needs that aren't in
          # {Workspace#readable}. Each is +--ro-bind+'d if it exists on
          # the host; missing entries are skipped silently (older or
          # unusual layouts).
          SYSTEM_ROOTS = %w[/lib /lib64 /bin /sbin].freeze

          # +/etc+ file allowlist for the subprocess. Each is +--ro-bind+'d
          # if it exists on the host. Nothing else from +/etc+ is exposed —
          # no +shadow+, no SSH config, no NetworkManager state.
          ETC_BASELINE = %w[
            /etc/ssl
            /etc/ca-certificates
            /etc/pki
            /etc/resolv.conf
            /etc/nsswitch.conf
            /etc/localtime
            /etc/hosts
          ].freeze

          # Container / VM control sockets that, if reachable from inside the
          # sandbox, give the bash subprocess a one-step path to
          # root-equivalent host access (the Docker daemon honors +docker run
          # --privileged -v / /host+; same for containerd, CRI-O, rootful
          # podman, buildkit, libvirt, LXD). The pikuri default workspace never
          # exposes +/var+ or +/run+, so these are unreachable by default;
          # {.reject_container_socket_exposure!} guards the *configuration*
          # surface — a downstream binary adding the docker socket to
          # +workspace.writable+ would unknowingly hand the LLM the keys.
          #
          # Rootless variants under +$XDG_RUNTIME_DIR+ / +/run/user/$UID/+ are
          # computed at class-load time. Not exhaustive; covers the engines
          # most likely on a Linux dev box. A downstream host can subclass and
          # extend.
          DENIED_CONTAINER_SOCKETS = begin
            xdg_runtime = ENV['XDG_RUNTIME_DIR'] || "/run/user/#{Process.uid}"
            paths = %w[
              /var/run/docker.sock
              /run/docker.sock
              /var/run/containerd/containerd.sock
              /run/containerd/containerd.sock
              /var/run/crio/crio.sock
              /run/crio/crio.sock
              /run/podman/podman.sock
              /var/run/podman/podman.sock
              /run/buildkit/buildkitd.sock
              /var/run/buildkit/buildkitd.sock
              /var/run/libvirt/libvirt-sock
              /run/libvirt/libvirt-sock
              /var/lib/lxd/unix.socket
              /var/snap/lxd/common/lxd/unix.socket
            ]
            paths.concat([
              "#{xdg_runtime}/docker.sock",
              "#{xdg_runtime}/podman/podman.sock"
            ])
            paths.map { |p| Pathname.new(p) }.uniq.freeze
          end

          # @param filesystem [Pikuri::Workspace::Filesystem] source of the
          #   per-host readable/writable roots, the +chdir+ target, and the
          #   parent of the per-session overlay state
          #   ({Workspace::Filesystem#internal_temp}). Every +readable+ dir is
          #   mounted as a read-write ephemeral overlay (or +--ro-bind+ without
          #   overlayfs-in-userns); see the class header.
          # @raise [RuntimeError] if +/+ is writable (pass {NONE} instead), if
          #   +temp+ is set but +alias_tmp_to_temp+ isn't, if any path equals or
          #   contains a {DENIED_CONTAINER_SOCKETS} entry, or if +bwrap+ is
          #   missing / fails its basic probe. A *separate* overlayfs probe
          #   failure does NOT raise — it degrades to read-only binds.
          def initialize(filesystem:)
            @filesystem = filesystem
            reject_unbounded_workspace!
            reject_unaliased_temp!
            reject_container_socket_exposure!
            check_bwrap!
          end

          # @param argv [Array<String>] the +timeout … bash -c <cmd>+ argv
          #   {Bash.run} would have spawned unmediated.
          # @return [Array<String>] +bwrap+ + isolation flags + bind-mounts +
          #   +argv+, ready for {Pikuri::Subprocess.spawn}.
          def wrap(argv)
            [BWRAP_BINARY, *bwrap_args, *argv]
          end

          # @return [Boolean] +true+ — this sandbox contains the filesystem but
          #   keeps +--share-net+, which +gem+/+bundle+/+mvn+/+pip+ need
          def egress? = true

          # @return [Boolean] +true+ — {#initialize} refuses a workspace listing
          #   +/+ as writable, so the bind set really is a subset of the host
          def confined_to_workspace? = true

          private

          # Refuse to construct when +/+ is in the writable set (typically
          # {Workspace::Filesystem::AllowAll}) — filesystem containment is moot
          # when the whole filesystem is the workspace.
          def reject_unbounded_workspace!
            return unless @filesystem.writable.include?(Pathname.new('/').realpath)

            raise "Code::Bash::Sandbox::Bubblewrap: workspace lists '/' as " \
                  'writable (likely Workspace::Filesystem::AllowAll). ' \
                  'Bubblewrap exists to contain the subprocess to a subset ' \
                  'of the filesystem, which is moot when the whole filesystem ' \
                  'is the workspace. Pass Sandbox::NONE instead.'
          end

          # A temp bind at +/tmp+ only pays off if the workspace also rewrites
          # +/tmp/*+ in the file tools via +alias_tmp_to_temp+; otherwise the
          # LLM writes via bash then hits "outside workspace" on every file-tool
          # access to the same path. Fail at boot.
          def reject_unaliased_temp!
            return if @filesystem.temp.nil?
            return if @filesystem.alias_tmp_to_temp

            raise 'Code::Bash::Sandbox::Bubblewrap: workspace has temp set ' \
                  'but alias_tmp_to_temp is off. This sandbox binds ' \
                  'workspace.temp at /tmp inside the subprocess, which ' \
                  'requires the workspace to rewrite /tmp/* in the file ' \
                  'tools so bash and file tools agree on one path. ' \
                  'Construct the workspace with alias_tmp_to_temp: true, ' \
                  'or pass Sandbox::NONE if you do not want the bind.'
          end

          # A workspace root that equals or contains a container/VM control
          # socket effectively neutralizes the sandbox (+docker run
          # --privileged -v / /host+ from inside is a one-step root escape).
          # A root +R+ exposes socket +S+ iff +R == S+ or +S+ is below +R+.
          def reject_container_socket_exposure!
            exposed = []
            roots = (@filesystem.writable + @filesystem.readable).uniq
            DENIED_CONTAINER_SOCKETS.each do |sock|
              root = roots.find do |r|
                r == sock || sock.to_s.start_with?(r.to_s + File::SEPARATOR)
              end
              exposed << [root, sock] if root
            end
            return if exposed.empty?

            details = exposed.map { |r, s| "  - #{s} (via workspace root #{r})" }.join("\n")
            raise "Code::Bash::Sandbox::Bubblewrap: workspace would expose " \
                  "container/VM control sockets to the sandbox:\n#{details}\n\n" \
                  "Reaching any of these from inside the sandbox is a one-step " \
                  "root escape (e.g. 'docker run --privileged -v / /host'). " \
                  'Remove the offending paths from workspace.readable / ' \
                  'workspace.writable, or pass Sandbox::NONE if you genuinely ' \
                  'intend the agent to drive a container daemon.'
          end

          # Probe +bwrap+ (raises if missing or user namespaces are
          # unsupported), then probe overlayfs and cache the verdict in
          # +@overlay_supported+. The overlay probe runs only when at least one
          # dir would actually be overlaid (a +readable+ entry not already a
          # +writable+ +--bind+), so a project-root-only workspace skips it.
          def check_bwrap!
            result = Sandbox.probe('--unshare-all', '--share-net', '--ro-bind', '/', '/')
            unless result.status.success?
              raise "Code::Bash::Sandbox::Bubblewrap: bwrap probe failed " \
                    "(exit #{result.status.exitstatus}). Is user-namespace " \
                    'support enabled in the kernel? Pass --no-sandbox to skip.'
            end

            overlayable = @filesystem.readable - @filesystem.writable
            @overlay_supported = overlayable.empty? ? false : probe_overlay_support?
          rescue Errno::ENOENT
            raise "Code::Bash::Sandbox::Bubblewrap: 'bwrap' not found on PATH. " \
                  'Install bubblewrap (apt-get install bubblewrap / dnf install ' \
                  'bubblewrap / pacman -S bubblewrap) or pass --no-sandbox.'
          end

          # Second-stage probe: overlayfs-in-userns needs Linux ≥ 5.11, which
          # the basic {#check_bwrap!} probe doesn't exercise. Unlike that one
          # this does NOT raise on failure — it logs a warning and returns
          # +false+, and {#bwrap_args} falls back to +--ro-bind+.
          #
          # Uses +--overlay-src /usr --tmp-overlay /tmp+: +/usr+ is the
          # read-only lower (always present, not an ancestor of +/tmp+ —
          # overlayfs forbids ancestor relationships), tmpfs backs the upper.
          # No host paths to manage; +--tmp-overlay+ refuses to construct
          # without at least one +--overlay-src+.
          #
          # @return [Boolean] whether overlayfs-in-userns works here.
          def probe_overlay_support?
            result = Sandbox.probe(
              '--unshare-all', '--share-net', '--ro-bind', '/', '/',
              '--overlay-src', '/usr', '--tmp-overlay', '/tmp'
            )
            return true if result.status.success?

            LOGGER.warn(
              "overlayfs in a user namespace is unavailable (bwrap overlay probe " \
              "exit #{result.status.exitstatus}; Linux >= 5.11 required). Falling " \
              'back to read-only binds for toolchain dirs — gem/bundle/pip/build ' \
              'installs into read-only toolchain dirs will fail with EROFS. Pass ' \
              '--no-sandbox to disable the sandbox entirely.'
            )
            false
          end

          def bwrap_args
            args = []
            mounted = Set.new

            # 1. OS-runtime baseline — NOT in workspace by design.
            (SYSTEM_ROOTS + ETC_BASELINE).each do |p|
              next unless File.exist?(p)
              next if mounted.include?(p)
              args.concat(['--ro-bind', p, p])
              mounted << p
            end

            # 2. Synthetic /proc + /dev. /tmp is handled separately
            #    below — when the workspace has a temp dir we bind it
            #    at /tmp (so the LLM's reflexive /tmp writes persist
            #    across bash calls); otherwise we fall back to tmpfs.
            args.concat(['--proc', '/proc', '--dev', '/dev'])

            if @filesystem.temp
              args.concat(['--bind', @filesystem.temp.to_s, '/tmp'])
              mounted << '/tmp'
            else
              args.concat(['--tmpfs', '/tmp'])
              mounted << '/tmp'
            end

            # 3. Workspace-derived mounts. Writable wins on overlap
            #    (writable ⊆ readable in the Workspace constructor;
            #    iterating writable first + the `mounted` guard
            #    ensures each path is mounted once). Writable paths are
            #    plain read+write --bind (persistent). Readable paths
            #    are read-write ephemeral overlays when overlayfs is
            #    supported (so toolchain installs succeed but vanish at
            #    session exit), falling back to --ro-bind otherwise.
            @filesystem.writable.each do |p|
              s = p.to_s
              next if mounted.include?(s)
              args.concat(['--bind', s, s])
              mounted << s
            end
            @filesystem.readable.each do |p|
              s = p.to_s
              next if mounted.include?(s)
              args.concat(@overlay_supported ? overlay_mount_args(s) : ['--ro-bind', s, s])
              mounted << s
            end

            # 4. Isolation + chdir.
            args.concat([
              '--unshare-all', '--share-net',
              '--die-with-parent', '--new-session',
              '--chdir', @filesystem.project_root.to_s
            ])
            args
          end

          # Lazily mint +<workspace.internal_temp>/overlay-<slug>/{upper,work}+
          # for +path+ and return the +bwrap+ fragment mounting an overlayfs at
          # +path+ with the host's real +path+ as the read-only lower. The
          # umbrella + its Finalizers-driven cleanup are owned by the workspace;
          # touching {Workspace::Filesystem#internal_temp} here triggers the
          # lazy mint. Called on every +wrap+: +mkdir_p+ is idempotent and is
          # the cheapest recovery from a mid-session umbrella wipe.
          #
          # *Concurrency:* the +upper+/+work+ paths are not safe to mount from
          # two live overlays at once (+EBUSY+) — fine because {Bash} serializes
          # bash calls; see the class header's "Concurrency". A downstream host
          # parallelizing through one {Bubblewrap} would hit +EBUSY+ at the
          # second mount.
          def overlay_mount_args(path)
            slug = path.gsub(/[^A-Za-z0-9._-]/, '_').sub(/\A_+/, '')
            overlay_dir = @filesystem.internal_temp + "overlay-#{slug}"
            upper = overlay_dir + 'upper'
            work  = overlay_dir + 'work'
            FileUtils.mkdir_p(upper)
            FileUtils.mkdir_p(work)
            ['--overlay-src', path, '--overlay', upper.to_s, work.to_s, path]
          end
        end

        # Full-filesystem, network-severed sandbox — the inverse of
        # {Bubblewrap}. Binds the entire real root read-write (+--dev-bind / /+)
        # and unshares *only* the network (+--unshare-net+). This is the sandbox
        # for the offline OS-helper agent (+bin/pikuri-os+): its job is to operate
        # the real host, so filesystem containment is the wrong tool and egress
        # is the whole risk. With the network namespace unshared *and* the live
        # session's IPC surface masked ({SESSION_IPC_MASKS} — both halves are
        # load-bearing), an injection in a file the agent reads has nowhere to
        # exfiltrate to — the trifecta's egress leg is cut by the kernel, not a
        # prompt. Full design + threat model in +pikuri-code/design/architecture.md+.
        #
        # == What's bound
        #
        # * +--dev-bind / /+ — the entire real root, read-write, no overlays.
        #   Unprivileged, so +bwrap+'s user namespace maps the caller's uid to
        #   itself: root-owned files (+/etc/*+, another user's +$HOME+) stay
        #   *not* writable and +/etc/shadow+ unreadable — privileged edits need
        #   +sudo+, unavailable in the namespace, so they route to the human.
        # * +--dev-bind /dev /dev+ — the *real* device tree, not bwrap's
        #   synthetic +--dev+. Redundant with the root bind but stated so it
        #   survives someone narrowing that bind: a synthetic +/dev+ omits the
        #   block nodes (+/dev/nvme0n1+) and turns +smartctl+'s honest +EACCES+
        #   into a confusing +ENOENT+, corrupting the model's error signal (full
        #   argument in +pikuri-code/design/architecture.md+).
        #
        #   +--dev-bind+, never plain +--bind+, for both: +--bind+ applies
        #   +MS_NODEV+, which leaves nodes visible to +ls+/+stat+ but unopenable
        #   (+echo x > /dev/null+ ⇒ +EACCES+ on a +crw-rw-rw-+ file). It grants
        #   no authority the caller lacks unsandboxed — node permissions and the
        #   uid map still apply.
        # * +--proc /proc+ over the bound root. PID is *not* unshared (see
        #   Isolation), so +/proc+ still shows host processes — essential for
        #   +ps+/+top+/+systemctl status+.
        #
        # == What's masked
        #
        # {SESSION_IPC_MASKS} — the user's live session sockets, the one hole
        # punched back out of that full-root bind. It's what makes this agent
        # *headless*: no GUI launching, by design.
        #
        # == Isolation: network only, deliberately
        #
        # +--unshare-net+ and nothing else. PID, IPC and UTS are *kept shared*
        # — unlike {Bubblewrap}'s +--unshare-all+ — because an OS helper must
        # see and reason about host processes and services (unsharing PID would
        # blind +ps+/+systemctl+). +--die-with-parent --new-session+ for the
        # same hygiene as Bubblewrap.
        #
        # == No fallback
        #
        # If +bwrap+ is missing or the kernel forbids unprivileged user/network
        # namespaces, the constructor *raises* — it does NOT degrade to a
        # networked run (the opposite of {Bubblewrap}'s overlay probe). Here the
        # severed network IS the security property. Fix the kernel setting (e.g.
        # +kernel.unprivileged_userns_clone+) or don't run this agent there.
        #
        # The full-root bind still exposes the *rootful* container/VM control
        # sockets under +/run+ (a confirmed +docker run --network=host+ has full
        # connectivity; only the rootless variants vanish with the runtime-dir
        # mask), so this is not a malware boundary — it severs the agent's *own*
        # egress; the non-defenses are in +pikuri-code/design/architecture.md+. A hard
        # boundary means running the whole agent inside a container / VM.
        class FullFsNoNet
          # Directory holding the X11 display sockets.
          X11_SOCKET_DIR = '/tmp/.X11-unix'

          # +bwrap+ flags hiding the user's live session sockets (bus, Wayland,
          # X11, keyring, ssh-agent, a rootless container daemon) from the
          # sandbox. On a desktop host:
          #
          #   ["--tmpfs", "/run/user/1000", "--tmpfs", "/tmp/.X11-unix"]
          #
          # Empty where there's no session — a CI container, a bare tty. A stray
          # +DBUS_SESSION_BUS_ADDRESS+ outside both dirs gets its own
          # +/dev/null+ mask.
          #
          # Load-bearing for the egress cut, not hygiene: a reachable session bus
          # spawns commands *outside* every namespace, so +--unshare-net+ without
          # this isn't a cut. Abstract-namespace sockets (+@/tmp/.X11-unix/X0+)
          # need no mask — the unshared netns already scopes them. Measurements and
          # the residual paths in +pikuri-code/design/architecture.md+; the capability trade in
          # +design/decisions.md+ +D_headless_os_agent+.
          SESSION_IPC_MASKS = begin
            dirs = [ENV['XDG_RUNTIME_DIR'], "/run/user/#{Process.uid}", X11_SOCKET_DIR].compact.uniq
            masks = dirs.select { |d| File.directory?(d) }.flat_map { |d| ['--tmpfs', d] }
            bus = ENV['DBUS_SESSION_BUS_ADDRESS']&.slice(/unix:path=([^,;]+)/, 1)
            if bus && File.exist?(bus) && dirs.none? { |d| bus.start_with?("#{d}/") }
              masks.concat(['--ro-bind', '/dev/null', bus])
            end
            masks.freeze
          end

          # @param filesystem [Pikuri::Workspace::Filesystem] used only for its
          #   +project_root+ (the +--chdir+ target); the bind set is the whole
          #   real root regardless, so the readable/writable lists are ignored.
          #   Pairs naturally with {Workspace::Filesystem::AllowAll}, which
          #   {Bubblewrap} rejects and this sandbox embraces.
          # @raise [RuntimeError] if +bwrap+ isn't on +PATH+, or if the kernel
          #   refuses an unprivileged user / network namespace (so the network
          #   can't be severed). Deliberately no fallback — see the class header.
          def initialize(filesystem:)
            @filesystem = filesystem
            check_bwrap!
          end

          # @param argv [Array<String>] the +timeout … bash -c <cmd>+ argv
          #   {Bash.run} would have spawned unmediated.
          # @return [Array<String>] +bwrap+ + full-root dev-bind + the real /dev
          #   + fresh /proc + {SESSION_IPC_MASKS} + +--unshare-net+ + isolation +
          #   +argv+, ready for {Pikuri::Subprocess.spawn}.
          def wrap(argv)
            [
              BWRAP_BINARY,
              '--dev-bind', '/', '/',
              '--dev-bind', '/dev', '/dev',
              '--proc', '/proc',
              *SESSION_IPC_MASKS,
              '--unshare-net',
              '--die-with-parent', '--new-session',
              '--chdir', @filesystem.project_root.to_s,
              *argv
            ]
          end

          # +false+ — and the +false+ is earned by {SESSION_IPC_MASKS} as much
          # as by +--unshare-net+. A network namespace binds *your process
          # tree*, not what that tree can ask someone else to do: with the
          # session bus reachable, +systemd-run --user curl+ returns HTTP 200
          # from inside this sandbox. Both halves must hold, and {#initialize}
          # raises rather than degrade if the kernel refuses the namespace, so
          # there is no path where this answers +false+ without the severance.
          #
          # @return [Boolean]
          def egress? = false

          # @return [Boolean] +false+ — +--dev-bind / /+ hands the subprocess
          #   the whole real root, whatever the workspace was scoped to
          def confined_to_workspace? = false

          private

          # Probe the exact isolation we rely on: a full-root dev-bind, the
          # session-IPC masks, and a *network-unshared* namespace. Unlike
          # {Bubblewrap}'s probe (which keeps +--share-net+), this MUST exercise
          # +--unshare-net+ so a kernel forbidding unprivileged net namespaces
          # fails here, loudly — never degrading to a networked run. +--dev-bind+
          # and {SESSION_IPC_MASKS} to match {#wrap} flag-for-flag: a probe of a
          # mount shape the real argv doesn't use proves nothing, and a mask this
          # host refuses must fail at boot, not on the first command.
          #
          # @raise [RuntimeError] on probe failure or missing +bwrap+.
          def check_bwrap!
            result = Sandbox.probe('--dev-bind', '/', '/', *SESSION_IPC_MASKS, '--unshare-net')
            return if result.status.success?

            raise 'Code::Bash::Sandbox::FullFsNoNet: bwrap probe failed ' \
                  "(exit #{result.status.exitstatus}). The network sandbox " \
                  'needs unprivileged user + network namespaces; some hardened ' \
                  'kernels disable them (e.g. kernel.unprivileged_userns_clone=0). ' \
                  'This sandbox does NOT fall back to a networked run — severing ' \
                  'the network is the security property. Fix the kernel setting, ' \
                  'or do not run the OS assistant on this host.'
          rescue Errno::ENOENT
            raise "Code::Bash::Sandbox::FullFsNoNet: 'bwrap' not found on PATH. " \
                  'Install bubblewrap (apt-get install bubblewrap / dnf install ' \
                  'bubblewrap / pacman -S bubblewrap). This agent runs every bash ' \
                  'command in a network-severed namespace; there is no fallback.'
          end
        end
      end
    end
  end
end
