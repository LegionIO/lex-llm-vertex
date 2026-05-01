# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Vertex
        module Transport
          module Exchanges
            # Topic exchange for Vertex provider availability events.
            class LlmRegistry < ::Legion::Transport::Exchange
              include Legion::Logging::Helper if defined?(Legion::Logging::Helper)

              def exchange_name
                'llm.registry'
              end

              def default_type
                'topic'
              end
            end
          end
        end
      end
    end
  end
end
