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

  it 'uses the provider-owned fleet runner' do
    expect(actor.runner_class).to eq('Legion::Extensions::Llm::Vertex::Runners::FleetWorker')
    expect(actor.runner_function).to eq('handle_fleet_request')
    expect(actor.use_runner?).to be(false)
  end

  it 'is enabled only when at least one provider instance responds to fleet requests' do
    allow(Legion::Extensions::Llm::Vertex).to receive(:discover_instances)
      .and_return(local: { fleet: { respond_to_requests: true } })
    allow(responder).to receive(:enabled_for?).and_return(true)

    expect(actor.enabled?).to be(true)
    expect(responder).to have_received(:enabled_for?).with(local: { fleet: { respond_to_requests: true } })
  end
end
