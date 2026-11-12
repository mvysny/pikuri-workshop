# frozen_string_literal: true

require 'etc'

module Pikuri
  module Os
    # Boot-time machine facts for the OS helper: a small block folded into
    # the system prompt so the model doesn't guess the distro, init system,
    # or paths. Narrative in book/os-assistant.md.
    #
    # The core facts (distro, kernel, init, packaging, desktop, CPU/mem,
    # home, shell, dmesg access, date) come from **always-present
    # primitives** — +Etc+, +/etc/os-release+, +/proc+, +ENV+, a +$PATH+
    # probe — so the block is deterministic, needs no external binary, and
    # works headless or in CI. The dmesg line is read from
    # +kernel.dmesg_restrict+ (not by spawning +dmesg+) so the model knows
    # up front whether the kernel log is readable. When +inxi+ is present,
    # +inxi -b+ output is appended as extra hardware/desktop detail; it is
    # enrichment, never a dependency — a missing or failing +inxi+ is never
    # fatal.
    #
    # A read-once-at-boot snapshot (the date is "at startup"). The host
    # doesn't change distro mid-session, and {#prompt_section} is
    # **memoized** so the +inxi+ subprocess runs once no matter how often
    # the prompt is re-assembled. Unlike {MachineMemory}, this deliberately
    # does *not* refresh on {Pikuri::Agent#clear_conversation}.
    class SystemInfo
      # @return [Integer] cap on the appended +inxi -b+ block, so a chatty
      #   inxi can't bloat the prompt.
      INXI_MAX_BYTES = 4 * 1024

      # Native package managers, in detection order: +[command, distro
      # hint]+. The first on +$PATH+ wins and is reported as this host's
      # primary manager. flatpak/snap are detected separately (cross-distro,
      # can coexist) — see {#packaging}.
      NATIVE_PACKAGE_MANAGERS = [
        ['apt',          'Debian/Ubuntu, dpkg'],
        ['dnf',          'Fedora/RHEL, rpm'],
        ['yum',          'RHEL/CentOS, rpm'],
        ['zypper',       'openSUSE, rpm'],
        ['pacman',       'Arch'],
        ['apk',          'Alpine'],
        ['xbps-install', 'Void'],
        ['emerge',       'Gentoo, portage'],
        ['eopkg',        'Solus']
      ].freeze

      # Ordered (fact-key, label) pairs for {.render}. A +nil+ value is
      # skipped, so a fact we couldn't read just doesn't appear.
      FACT_ORDER = [
        [:os,        'OS'],
        [:kernel,    'Kernel'],
        [:init,      'Init'],
        [:packaging, 'Packaging'],
        [:desktop,   'Desktop'],
        [:hostname,  'Hostname'],
        [:home,      'Home'],
        [:shell,     'Shell'],
        [:cpus,      'CPUs'],
        [:memory,    'Memory'],
        [:dmesg,     'Kernel log (dmesg)'],
        [:date,      'Date (at startup)']
      ].freeze

      # The system-prompt grounding section: a +# This machine+ heading,
      # a one-line "trust these over your guesses" nudge, the core facts,
      # and (when +inxi+ is present) an extra-detail block.
      # Memoized (see class doc).
      #
      # @return [String]
      def prompt_section
        @prompt_section ||= begin
          parts = ['# This machine', '',
                   'Rely on these facts rather than guessing the distro, paths, or init system.',
                   '', self.class.render(facts)]
          detail = inxi_detail
          parts += ['', 'Further hardware/desktop detail (from `inxi -b`):', detail] if detail
          parts.join("\n")
        end
      end

      # Render a facts hash as +"- Label: value"+ lines in {FACT_ORDER},
      # skipping keys with no value. Pure — the testable core.
      #
      # @param facts [Hash{Symbol=>Object}]
      # @return [String]
      def self.render(facts)
        FACT_ORDER.filter_map do |key, label|
          value = facts[key]
          "- #{label}: #{value}" unless value.nil? || value.to_s.strip.empty?
        end.join("\n")
      end

      # The core facts, each gathered best-effort (a reader that fails
      # yields +nil+ and the line is dropped).
      #
      # @return [Hash{Symbol=>Object}]
      def facts
        {
          os:        os_pretty_name,
          kernel:    kernel_string,
          init:      init_system,
          packaging: packaging,
          desktop:   presence(ENV['XDG_CURRENT_DESKTOP']),
          hostname:  uname[:nodename],
          home:      home_dir,
          shell:     presence(ENV['SHELL']),
          cpus:      cpu_count,
          memory:    total_memory,
          dmesg:     dmesg_access,
          date:      Time.now.strftime('%Y-%m-%d %H:%M:%S %z')
        }
      end

      private

      # The host's package-management surface: the primary native manager
      # (first {NATIVE_PACKAGE_MANAGERS} entry on +$PATH+, with its distro
      # hint) followed by whichever of flatpak / snap are installed, e.g.
      # +"apt (Debian/Ubuntu, dpkg); flatpak"+. +nil+ when none are found
      # (so the line is dropped rather than asserting a bare box has no way
      # to install software).
      #
      # @return [String, nil]
      def packaging
        native = NATIVE_PACKAGE_MANAGERS.find { |cmd, _| on_path?(cmd) }
        parts = []
        parts << "#{native[0]} (#{native[1]})" if native
        parts << 'flatpak' if on_path?('flatpak')
        parts << 'snap' if on_path?('snap')
        parts.empty? ? nil : parts.join('; ')
      end

      # Whether this user can read the kernel ring buffer (+dmesg+), decided
      # from +kernel.dmesg_restrict+ rather than by spawning +dmesg+ — so
      # the model knows in advance whether a +dmesg+ call returns logs or
      # fails with "read kernel buffer failed: Operation not permitted".
      # +nil+ (line dropped) when +dmesg+ isn't installed.
      #
      # @return [String, nil]
      def dmesg_access
        return nil unless on_path?('dmesg')
        return 'readable (running as root)' if Process.uid.zero?

        case File.read('/proc/sys/kernel/dmesg_restrict').strip
        when '0' then 'readable'
        when '1' then 'restricted as this user — needs sudo (kernel.dmesg_restrict=1)'
        end
      rescue SystemCallError
        # dmesg_restrict absent on this kernel: unprivileged reads are the
        # historical default, so treat it as readable rather than guessing.
        'likely readable (kernel.dmesg_restrict unset)'
      end

      # @param name [String] a bare command name, e.g. "flatpak"
      # @return [Boolean] true if an executable by that name is on +$PATH+
      def on_path?(name)
        ENV['PATH'].to_s.split(File::PATH_SEPARATOR).any? do |dir|
          next false if dir.empty?

          path = File.join(dir, name)
          File.file?(path) && File.executable?(path)
        end
      end

      # +inxi -b -c 0+ output (color stripped) when inxi is on PATH, capped
      # to {INXI_MAX_BYTES}; +nil+ when inxi is absent, errors, or is
      # empty. Never raises out — enrichment only.
      #
      # @return [String, nil]
      def inxi_detail
        result = Pikuri::Subprocess.spawn('inxi', '-b', '-c', '0', chdir: '/').wait
        return nil unless result.status.success?

        out = result.output.strip
        return nil if out.empty?

        out.bytesize > INXI_MAX_BYTES ? "#{out.byteslice(0, INXI_MAX_BYTES)}\n…" : out
      rescue Errno::ENOENT
        nil
      end

      # @return [String, nil] +PRETTY_NAME+ from +/etc/os-release+
      def os_pretty_name
        line = File.foreach('/etc/os-release').find { |l| l.start_with?('PRETTY_NAME=') }
        return nil unless line

        line.split('=', 2).last.strip.delete_prefix('"').delete_suffix('"')
      rescue SystemCallError
        nil
      end

      # @return [String, nil] +"<release> <machine>"+, e.g. "7.0.0-27-generic x86_64"
      def kernel_string
        u = uname
        return nil unless u[:release]

        [u[:release], u[:machine]].compact.join(' ')
      end

      # @return [Hash] memoized +Etc.uname+ (sysname/nodename/release/…),
      #   or +{}+ if unavailable.
      def uname
        @uname ||= (Etc.uname rescue {})
      end

      # @return [String, nil] PID 1's command (e.g. "systemd")
      def init_system
        presence(File.read('/proc/1/comm').strip)
      rescue SystemCallError
        nil
      end

      # @return [String, nil]
      def home_dir
        Dir.home
      rescue ArgumentError
        presence(ENV['HOME'])
      end

      # @return [Integer, nil]
      def cpu_count
        Etc.nprocessors
      rescue StandardError
        nil
      end

      # @return [String, nil] total RAM, e.g. "23.5 GiB", from /proc/meminfo
      def total_memory
        line = File.foreach('/proc/meminfo').find { |l| l.start_with?('MemTotal:') }
        return nil unless line

        kb = line[/(\d+)/, 1]&.to_i
        return nil unless kb

        format('%.1f GiB', kb / 1024.0 / 1024.0)
      rescue SystemCallError
        nil
      end

      # @return [String, nil] +value+ unless nil/blank
      def presence(value)
        value && !value.to_s.strip.empty? ? value : nil
      end
    end
  end
end
