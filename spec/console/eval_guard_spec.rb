# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/eval_guard'

RSpec.describe Woods::Console::EvalGuard do
  describe '.check!' do
    context 'with payloads that should pass' do
      it 'allows a plain ActiveRecord query' do
        expect { described_class.check!('User.count') }.not_to raise_error
      end

      it 'allows a where chain with literal arguments' do
        expect { described_class.check!('User.where(active: true).limit(10)') }.not_to raise_error
      end

      it 'allows a multi-line script with safe references' do
        code = <<~RUBY
          users = User.where(active: true)
          users.pluck(:email)
        RUBY
        expect { described_class.check!(code) }.not_to raise_error
      end

      it 'allows reading non-credential files' do
        expect { described_class.check!('File.read("README.md")') }.not_to raise_error
      end
    end

    context 'with credential call chains' do
      it 'rejects Rails.application.credentials chain' do
        expect { described_class.check!('Rails.application.credentials.stripe.secret_key') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /Rails\.application\.credentials/)
      end

      it 'rejects Rails.application.credentials.dig' do
        expect { described_class.check!('Rails.application.credentials.dig(:stripe, :key)') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /Rails\.application\.credentials/)
      end

      it 'rejects Rails.application.secrets chain' do
        expect { described_class.check!('Rails.application.secrets.stripe_key') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /Rails\.application\.secrets/)
      end

      it 'rejects Rails::Secrets.parse' do
        expect { described_class.check!('Rails::Secrets.parse("config/secrets.yml")') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /Rails::Secrets/)
      end

      it 'rejects Devise.secret_key access' do
        expect { described_class.check!('Devise.secret_key') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /Devise\.secret_key/)
      end
    end

    context 'with ENV references' do
      it 'rejects bare ENV access via subscript' do
        expect { described_class.check!('ENV["STRIPE_SECRET_KEY"]') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /ENV/)
      end

      it 'rejects ENV.fetch' do
        expect { described_class.check!('ENV.fetch("STRIPE_SECRET_KEY")') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /ENV/)
      end

      it 'rejects bare ENV reference' do
        expect { described_class.check!('puts ENV') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /ENV/)
      end
    end

    context 'with reflection escapes' do
      it 'rejects bare instance_eval' do
        expect { described_class.check!('User.first.instance_eval("self")') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /instance_eval/)
      end

      it 'rejects send with symbol method' do
        expect { described_class.check!('User.send(:delete_all)') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /send/)
      end

      it 'rejects const_get' do
        expect { described_class.check!('Object.const_get("User")') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /const_get/)
      end

      it 'rejects binding' do
        expect { described_class.check!('binding.local_variables') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /binding/)
      end

      # PR #34 medium #2: AST-reachable reflection bypasses
      it 'rejects instance_variable_get' do
        expect { described_class.check!('User.first.instance_variable_get(:@attributes)') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /instance_variable_get/)
      end

      it 'rejects method reference via .method' do
        expect { described_class.check!('User.method(:delete_all)') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /\bmethod\b/)
      end

      it 'rejects define_method' do
        expect { described_class.check!('User.define_method(:pwn) { puts "ok" }') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /define_method/)
      end

      it 'rejects const_source_location' do
        expect { described_class.check!('Object.const_source_location("User")') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /const_source_location/)
      end

      it 'rejects ObjectSpace._id2ref' do
        expect { described_class.check!('ObjectSpace._id2ref(42)') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /_id2ref/)
      end

      it 'rejects ObjectSpace.each_object' do
        expect { described_class.check!('ObjectSpace.each_object(String).to_a') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /each_object/)
      end
    end

    context 'with credential file reads' do
      it 'rejects File.read on master.key' do
        expect { described_class.check!('File.read("config/master.key")') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /File\.read/)
      end

      it 'rejects File.read on credentials.yml.enc' do
        expect { described_class.check!('File.read("config/credentials.yml.enc")') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /credential file/)
      end

      it 'rejects IO.read on a credentials/ path' do
        expect { described_class.check!('IO.read("config/credentials/production.yml.enc")') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /IO\.read/)
      end

      it 'rejects Pathname.new(...).read on master.key' do
        expect { described_class.check!('Pathname.new("config/master.key").read') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /Pathname\.(?:new|read)/)
      end

      # PR #34 medium #3: chained receiver bypasses
      it 'rejects File.open(credential_path).read chain' do
        expect { described_class.check!('File.open("config/master.key").read') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /credential file/)
      end

      it 'rejects File.open(credential_path).readlines chain' do
        expect { described_class.check!('File.open("config/credentials.yml.enc").readlines') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /credential file/)
      end

      it 'rejects Pathname.new(credential_path).open.read chain' do
        expect { described_class.check!('Pathname.new("config/master.key").open.read') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /credential file/)
      end

      it 'rejects IO.open(credential_path).read chain' do
        expect { described_class.check!('IO.open("config/credentials/production.yml.enc").read') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /credential file/)
      end
    end

    context 'with parse failures' do
      it 'refuses unparseable code' do
        expect { described_class.check!('class Foo; def bar; end; end; def') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /parsed safely/)
      end

      it 'refuses an empty payload' do
        expect { described_class.check!('') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /empty/)
      end

      it 'refuses a nil payload' do
        expect { described_class.check!(nil) }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /empty/)
      end
    end

    context 'with shell-exec + escape vectors' do
      it 'rejects backtick literals (`cmd`)' do
        expect { described_class.check!('`ls /tmp`') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /shell-execution/)
      end

      it 'rejects %x{cmd} literals' do
        expect { described_class.check!('%x{ls /tmp}') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /shell-execution/)
      end

      it 'rejects Kernel system/exec/spawn methods' do
        expect { described_class.check!('system("ls")') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /system/)
        expect { described_class.check!('exec("ls")') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /exec/)
        expect { described_class.check!('spawn("ls")') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /spawn/)
      end

      it 'rejects Marshal/YAML unsafe deserialization' do
        expect { described_class.check!('Marshal.load(payload)') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /Marshal/)
        expect { described_class.check!('YAML.unsafe_load(payload)') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /(YAML|unsafe_load)/)
      end

      it 'rejects Thread.new (would escape SafeContext rollback)' do
        expect { described_class.check!('Thread.new { User.delete_all }') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /Thread/)
      end

      it 'rejects __send__ (classic send-blocklist bypass)' do
        expect { described_class.check!('obj.__send__(:destroy)') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /__send__/)
      end

      it 'rejects network egress constants (Net, URI, Socket)' do
        # `Net::HTTP.get(u)` — both `Net` and `HTTP` are on the denylist;
        # whichever is scanned first triggers refusal.
        expect { described_class.check!('Net::HTTP.get(u)') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /(Net|HTTP)/)
        expect { described_class.check!('URI.open("http://x")') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /URI/)
      end
    end

    # Regression: a payload like `@audit_logger = nil; 1` could previously
    # silence the executor's audit log by writing to its instance variables.
    # The embedded eval path now runs inside a throwaway receiver, but we
    # also deny the syntactic forms as defense-in-depth.
    context 'with variable-assignment bypass attempts' do
      it 'rejects instance-variable assignment' do
        expect { described_class.check!('@audit_logger = nil') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /instance variable @audit_logger/)
      end

      it 'rejects class-variable assignment' do
        expect { described_class.check!('@@global_flag = true') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /@@global_flag/)
      end

      it 'rejects global-variable assignment' do
        expect { described_class.check!('$foo = 1') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /\$foo/)
      end

      it 'rejects multi-statement payloads that hide the assignment' do
        expect { described_class.check!('User.count; @audit_logger = nil') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /instance variable/)
      end

      it 'does not false-positive on equality comparisons' do
        expect { described_class.check!('User.where("name == ?", x)') }.not_to raise_error
      end

      # Op-assign forms are also writes — `$foo += 1` desugars to
      # `$foo = $foo + 1`. Plain `=`-only denial lets these slip.
      it 'rejects class-variable op-assign (+=)' do
        expect { described_class.check!('@@count += 1') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /@@count/)
      end

      it 'rejects global-variable op-assign (||=)' do
        expect { described_class.check!('$cache ||= {}') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /\$cache/)
      end

      it 'rejects global-variable shift-assign (<<=)' do
        expect { described_class.check!('$flags <<= 2') }
          .to raise_error(Woods::Console::ForbiddenExpressionError, /\$flags/)
      end

      # Non-assignment lookalikes must not false-positive.
      it 'does not false-positive on $foo =~ /x/ (match operator)' do
        expect { described_class.check!('$LAST_MATCH =~ /pattern/') }.not_to raise_error
      end

      it 'does not false-positive on $foo => value (hash rocket)' do
        expect { described_class.check!('{ $key => 1 }') }.not_to raise_error
      end

      it 'does not false-positive on $foo <= value (comparison)' do
        expect { described_class.check!('$counter <= 5') }.not_to raise_error
      end
    end
  end
end
