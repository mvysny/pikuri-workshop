# frozen_string_literal: true

RSpec.describe Pikuri::Code::Bash::Sandbox::EnvWall do
  let(:wall) { described_class.new }

  describe '.path_shaped?' do
    it 'accepts an absolute path and a colon-separated list of them' do
      assert described_class.path_shaped?('/usr/lib/jvm/java-21')
      assert described_class.path_shaped?('/usr/local/bin:/usr/bin::/bin')
    end

    it 'rejects a token, a URL and a relative path' do
      refute described_class.path_shaped?('ghp_0123456789abcdef')
      refute described_class.path_shaped?('postgres://app:hunter2@db/app')
      refute described_class.path_shaped?('build/out')
    end

    it 'rejects a base64 secret that happens to start with a slash' do
      refute described_class.path_shaped?('/aB3xK9qZ+r7Lw==')
    end

    it 'rejects an empty list and control characters' do
      refute described_class.path_shaped?('::')
      refute described_class.path_shaped?("/usr/bin\n/bin")
    end
  end

  describe '#passes?' do
    it 'passes the shell and terminal baseline, and every locale category' do
      %w[PATH HOME LANG TERM LC_ALL LC_MESSAGES].each { |name| assert wall.passes?(name, 'x'), name }
    end

    it 'passes build-tool options that are not paths' do
      assert wall.passes?('MAVEN_OPTS', '-Xmx2g')
      assert wall.passes?('NODE_OPTIONS', '--max-old-space-size=4096')
    end

    it 'passes path-valued variables, credential paths included — the filesystem wall governs those' do
      assert wall.passes?('JAVA_HOME', '/usr/lib/jvm/java-21')
      assert wall.passes?('GOOGLE_APPLICATION_CREDENTIALS', '/home/someone/key.json')
    end

    it 'passes an empty value' do
      assert wall.passes?('ANYTHING', '')
    end

    it 'withholds tokens, URLs with credentials and unknown words' do
      refute wall.passes?('GITHUB_TOKEN', 'ghp_0123456789abcdef')
      refute wall.passes?('DATABASE_URL', 'postgres://app:hunter2@db/app')
      refute wall.passes?('AWS_REGION', 'eu-west-1')
    end

    it 'passes a name the user let through, whatever its value' do
      assert described_class.new(pass: ['AWS_REGION']).passes?('AWS_REGION', 'eu-west-1')
    end
  end

  describe '#withheld' do
    it 'returns the rejected names, sorted' do
      env = { 'PATH' => '/usr/bin', 'Z_TOKEN' => 'secret', 'A_KEY' => 'secret' }
      assert_equal %w[A_KEY Z_TOKEN], wall.withheld(env)
    end
  end
end
