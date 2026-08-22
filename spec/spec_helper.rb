# frozen_string_literal: true

require 'bundler/setup'
require 'logger'

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
        # Functional stand-in for the LegionIO Lex helper, not an empty one:
        # the shared Discovery::Pipeline and the base Discovery::Actor
        # `include` it, and the provider runner relies on the real
        # log/handle_exception/settings the host helper provides.
        # `handle_exception` (from Legion::Logging::Helper) logs and does NOT
        # re-raise; `settings` (from Legion::Settings::Helper, real resolution
        # from legion-settings >= 1.4.2) resolves this two-segment extension
        # to the nested path
        # Legion::Settings[:extensions][:llm][:vertex] (the same path
        # CredentialSources.setting(:extensions, :llm, :vertex) reads) —
        # writable, which is how specs drive the health write-back and the
        # publish-time weight settings.
        module Lex
          include Legion::Logging::Helper
          include Legion::Settings::Helper

          # Mirror the real Lex: module-level consumers (the Runners::*
          # modules) get settings/log/handle_exception on the module itself.
          def self.included(base)
            base.extend(base) if base.instance_of?(Module) && !base.instance_of?(Class)
          end
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

# Sink all logging to /dev/null (log_stdout: false explicitly suppresses the
# stdout sink) so the required JSON-to-file RSpec run remains zero-stdout.
Legion::Logging.setup(
  level: 'debug',
  format: :text,
  async: false,
  trace: false,
  trace_size: 0,
  extended: false,
  log_file: File::NULL,
  log_stdout: false,
  include_pid: false,
  color: false
)
