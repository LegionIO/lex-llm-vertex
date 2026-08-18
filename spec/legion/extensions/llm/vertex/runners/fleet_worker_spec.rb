# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/vertex/runners/fleet_worker'

RSpec.describe Legion::Extensions::Llm::Vertex::Runners::FleetWorker do
  let(:message) do
    { request_id: 'req-1', provider: 'vertex', provider_instance: 'local', routing_key: 'amqp.runners.fleet.#' }
  end
  let(:instances) { { local: { fleet: { respond_to_requests: true } } } }
  let(:responder) { Legion::Extensions::Llm::Fleet::ProviderResponder }

  it 'delegates the decoded subscription message to the shared lex-llm responder helper' do
    allow(Legion::Extensions::Llm::Vertex).to receive(:discover_instances).and_return(instances)
    allow(responder).to receive(:call).and_return(:ok)

    result = described_class.handle_fleet_request(**message)

    expect(result).to eq(:ok)
    expect(responder).to have_received(:call).with(
      payload: message,
      provider_family: :vertex,
      provider_class: Legion::Extensions::Llm::Vertex::Provider,
      provider_instances: satisfy { |resolver| resolver.call == instances }
    )
  end
end
