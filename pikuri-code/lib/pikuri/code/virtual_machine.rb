# frozen_string_literal: true

module Pikuri
  module Code
    # Whether this process runs inside a virtual machine, for a binary that
    # lifts its cage: +--yolo+ and +--no-sandbox+ are for a VM, and saying so
    # only in +--help+ is easy to miss.
    #
    #   case Pikuri::Code::VirtualMachine.inside?
    #   when true  then 'the VM is the wall now'
    #   when false then 'NOT inside a VM'
    #   else            'cannot tell'
    #   end
    #
    # Asks +systemd-detect-virt --vm+, which reports hardware virtualization
    # only: a container does not count, since it shares your kernel.
    module VirtualMachine
      # The +systemd-detect-virt+(1) binary, resolved on +PATH+.
      DETECT_BINARY = 'systemd-detect-virt'

      # @return [Boolean, nil] +true+ inside a VM, +false+ outside one, +nil+
      #   when +systemd-detect-virt+ is missing
      def self.inside?
        Pikuri::Subprocess.spawn(DETECT_BINARY, '--vm', '--quiet', chdir: '/').wait.status.success?
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
