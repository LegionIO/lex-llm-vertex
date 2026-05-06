# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/vertex/runners/fleet_worker'

module Legion
  module LLM
    module Fleet
      unless const_defined?(:ProviderResponder, false)
        class ProviderResponder
          def self.call(**); end
        end
      end
    end
  end
end

FleetWorkerSpecDelivery = Class.new unless defined?(FleetWorkerSpecDelivery)
FleetWorkerSpecProperties = Class.new unless defined?(FleetWorkerSpecProperties)

RSpec.describe Legion::Extensions::Llm::Vertex::Runners::FleetWorker do
  let(:payload) { { request_id: 'req-1', provider: 'vertex', provider_instance: 'local' } }
  let(:delivery) { instance_double(FleetWorkerSpecDelivery) }
  let(:properties) { instance_double(FleetWorkerSpecProperties) }
  let(:instances) { { local: { fleet: { respond_to_requests: true } } } }
  let(:responder) { Legion::LLM::Fleet::ProviderResponder }

  it 'delegates fleet execution to the shared legion-llm responder helper' do
    allow(Legion::Extensions::Llm::Vertex).to receive(:discover_instances).and_return(instances)
    allow(responder).to receive(:call).and_return(:ok)

    result = described_class.handle_fleet_request(payload, delivery:, properties:)

    expect(result).to eq(:ok)
    expect(responder).to have_received(:call).with(
      payload: payload,
      provider_family: :vertex,
      provider_class: Legion::Extensions::Llm::Vertex::Provider,
      provider_instances: satisfy { |resolver| resolver.call == instances },
      delivery: delivery,
      properties: properties
    )
  end
end
