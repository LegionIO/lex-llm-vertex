# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Vertex
        # Best-effort publisher for Vertex provider availability events.
        class RegistryPublisher
          include Legion::Logging::Helper

          APP_ID = 'lex-llm-vertex'

          def initialize(builder: RegistryEventBuilder.new)
            @builder = builder
          end

          def publish_readiness_async(readiness)
            log.info { 'publishing readiness event to llm.registry' }
            schedule { publish_event(@builder.readiness(readiness)) }
          end

          def publish_offerings_async(offerings, readiness:)
            log.info { "publishing #{Array(offerings).size} offering event(s) to llm.registry" }
            schedule do
              Array(offerings).each do |offering|
                publish_event(@builder.offering_available(offering, readiness:))
              end
            end
          end

          private

          def schedule(&)
            return false unless publishing_available?

            Thread.new do
              Thread.current.abort_on_exception = false
              yield
            rescue StandardError => e
              handle_exception(e, level: :debug, handled: true, operation: 'vertex.registry.schedule_thread')
            end
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'vertex.registry.schedule')
            false
          end

          def publish_event(event)
            return false unless publishing_available?

            message_class.new(event:, app_id: APP_ID).publish(spool: false)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vertex.registry.publish_event')
            false
          end

          def publishing_available?
            return false unless registry_event_available?
            return false unless transport_message_available?
            return true unless defined?(::Legion::Transport::Connection)
            return true unless ::Legion::Transport::Connection.respond_to?(:session_open?)

            ::Legion::Transport::Connection.session_open?
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'vertex.registry.publishing_available?')
            false
          end

          def registry_event_available?
            defined?(::Legion::Extensions::Llm::Routing::RegistryEvent)
          end

          def transport_message_available?
            return true if message_class_defined?
            return false unless defined?(::Legion::Transport::Message) && defined?(::Legion::Transport::Exchange)

            require 'legion/extensions/llm/vertex/transport/messages/registry_event'
            message_class_defined?
          rescue LoadError => e
            handle_exception(e, level: :debug, handled: true, operation: 'vertex.registry.transport_load')
            false
          end

          def message_class_defined?
            defined?(::Legion::Extensions::Llm::Vertex::Transport::Messages::RegistryEvent)
          end

          def message_class
            ::Legion::Extensions::Llm::Vertex::Transport::Messages::RegistryEvent
          end
        end
      end
    end
  end
end
