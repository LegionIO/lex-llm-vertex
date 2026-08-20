# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'

module Legion
  module Extensions
    module Actors
      unless const_defined?(:Subscription, false)
        class Subscription
          def initialize(*) = true
        end
      end
    end
  end
end

require 'legion/extensions/llm/vertex/actors/fleet_worker'

RSpec.describe Legion::Extensions::Llm::Vertex::Actor::FleetWorker do
  subject(:actor) { described_class.new }

  let(:responder) { Legion::Extensions::Llm::Fleet::ProviderResponder }
  let(:message) do
    {
      request_id: 'req-1', provider: 'vertex', provider_instance: 'local',
      operation: 'chat', model: 'gemini-2.5-flash', routing_key: 'amqp.runners.fleet.#'
    }
  end

  it 'exposes a const runner_class with a kwargs-only runner entrypoint' do
    # The Subscription dispatch path (use_runner? = false) calls
    # runner_class.send(runner_function, **message) — runner_class must be a
    # send-able constant and the entrypoint must accept **message.
    expect(actor.runner_class).to eq(Legion::Extensions::Llm::Vertex::Runners::FleetWorker)
    expect(actor.runner_function).to eq('handle_fleet_request')
    expect(actor.use_runner?).to be(false)
    expect(actor.runner_class.method(:handle_fleet_request).parameters).to eq([%i[keyrest message]])
  end

  it 'dispatches a subscription message through the runner to the shared responder' do
    allow(responder).to receive(:call).and_return(:ok)

    # The exact call Legion::Extensions::Actors::Subscription makes when
    # use_runner? is false. Protocol v3: exact-only execution against the
    # SSOT registry — no provider construction wiring.
    result = actor.runner_class.send(actor.runner_function, **message)

    expect(result).to eq(:ok)
    expect(responder).to have_received(:call).with(
      payload: message,
      provider_family: :vertex,
      registry: Legion::Extensions::Llm::Inventory::Registry
    )
  end

  it 'is enabled only when at least one provider instance responds to fleet requests' do
    allow(Legion::Extensions::Llm::Vertex).to receive(:discover_instances)
      .and_return(local: { fleet: { respond_to_requests: true } })
    allow(responder).to receive(:enabled_for?).and_return(true)

    expect(actor.enabled?).to be(true)
    expect(responder).to have_received(:enabled_for?).with(local: { fleet: { respond_to_requests: true } })
  end

  private

  def instances_hash
    { local: { fleet: { respond_to_requests: true } } }
  end
end
