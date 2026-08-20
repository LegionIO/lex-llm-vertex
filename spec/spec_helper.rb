# frozen_string_literal: true

require 'bundler/setup'
require 'logger'
require 'stringio'

require 'legion/extensions/llm'
require 'legion/settings'

# The LegionIO actor runtime is not a gem dependency of this extension, so the
# offline spec environment stubs the runtime surface the actor files need. The
# stubs MUST be defined before 'legion/extensions/llm/vertex' is required (the
# entry module loads the discovery actor, which fails loudly without a runtime).
# In production the real LegionIO runtime is present and no stub is defined.
module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        # Stub base class for the discovery actor in the test context. It
        # defines no timer, so specs drive the actor through manual/shutdown.
        class Every
          def self.every_seconds = 300
        end
      end
    end

    module Helpers
      unless const_defined?(:Lex, false)
        # Stand-in for the LegionIO Lex helper: the REAL settings resolution
        # from legion-settings >= 1.4.2, which resolves this two-segment
        # extension to the nested path
        # Legion::Settings[:extensions][:llm][:vertex] (the same path
        # CredentialSources.setting(:extensions, :llm, :vertex) reads), so the
        # actor's settings reads/writes exercise genuine resolution.
        # log/handle_exception come from the real
        # Legion::Logging::Helper, which the actors include after Lex.
        module Lex
          include Legion::Settings::Helper
        end
      end
    end
  end
end

# Guarantee the extensions settings tree exists as a writable Hash so
# Settings::Helper#dig_or_create mutates the real tree (a pristine settings
# load with no :extensions key would make it return a throwaway hash).
Legion::Settings[:extensions] ||= {}

require 'legion/extensions/llm/vertex'

# Load the shared conformance examples from the lex-llm gem's spec/ directory
# (spec/ ships in the gem but is NOT on the load path). Only the shared
# examples files — the kit directory's own self-test specs belong to lex-llm's
# suite, not this provider's:
#   * ssot_provider_examples.rb — the SSOT v3 registry/fleet adapter group
#   * ssot_contract_examples.rb — the 0.8.0 boundary (B), fleet (F), and
#     registry (R) groups the conformance spec runs against the real callable
if Gem.loaded_specs['lex-llm']
  kit_dir = File.join(
    Gem.loaded_specs['lex-llm'].full_gem_path,
    'spec/legion/extensions/llm/conformance'
  )
  require File.join(kit_dir, 'ssot_provider_examples.rb')
  require File.join(kit_dir, 'ssot_contract_examples.rb')
end

if defined?(Legion::Logging)
  # Ruby 4 treats File::NULL passed as a String as a logger with no logdev;
  # legion-logging then deliberately falls back to stdout. Keep a real IO
  # sink so the required JSON-to-file RSpec run remains zero-stdout.
  null_logger = Logger.new(StringIO.new)
  null_logger.level = Logger::DEBUG
  Legion::Logging.instance_variable_set(:@log, null_logger)
  Legion::Logging.instance_variable_set(
    :@current_settings,
    {
      level: :debug,
      format: :text,
      async: false,
      trace: false,
      trace_size: 0,
      extended: false,
      log_file: nil,
      log_stdout: false,
      include_pid: false,
      color: false
    }.freeze
  )
  Legion::Logging.instance_variable_set(:@configuration_generation, Legion::Logging.configuration_generation + 1)
end
