# frozen_string_literal: true

require 'spec_helper'

class FakeVertexConnection
  attr_reader :posts, :gets

  def initialize
    @posts = []
    @gets = []
  end

  def post(url, payload)
    @posts << [url, payload]
    Struct.new(:body).new(response_for(url))
  end

  def get(url)
    @gets << url
    Struct.new(:body).new({ 'publisherModels' => [{ 'name' => 'publishers/google/models/gemini-2.5-flash' }] })
  end

  private

  def response_for(url)
    return embedding_response if url.end_with?(':predict')
    return token_response if url.end_with?(':countTokens')
    return raw_predict_response if url.include?(':rawPredict') || url.include?(':streamRawPredict')

    generate_content_response(url)
  end

  # The Vertex wire echoes the served model back — modelVersion mirrors the
  # model in the request URL, so the canonical response keeps the
  # Selection-derived model end-to-end (B4).
  def generate_content_response(url)
    {
      'modelVersion' => url[%r{models/([^:]+):}, 1],
      'candidates' => [{
        'content' => { 'parts' => [{ 'text' => 'done' }] },
        'finishReason' => 'STOP'
      }],
      'usageMetadata' => { 'promptTokenCount' => 3, 'candidatesTokenCount' => 5 }
    }
  end

  def raw_predict_response
    {
      'model' => 'mistral-medium-3',
      'choices' => [{ 'message' => { 'content' => 'raw done' }, 'finish_reason' => 'stop' }],
      'usage' => { 'prompt_tokens' => 2, 'completion_tokens' => 4 }
    }
  end

  def embedding_response
    {
      'predictions' => [
        { 'embeddings' => { 'values' => [0.1, 0.2], 'statistics' => { 'token_count' => 4 } } }
      ]
    }
  end

  def token_response
    { 'totalTokens' => 7 }
  end
end

RSpec.describe Legion::Extensions::Llm::Vertex do
  let(:canonical) { Legion::Extensions::Llm::Canonical }
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:connection) { FakeVertexConnection.new }
  let(:message) { canonical::Message.build(role: :user, content: 'hello') }

  before do
    Legion::Extensions::Llm.configure do |config|
      config.vertex_project = 'test-project'
      config.vertex_location = 'us-central1'
      config.vertex_access_token = 'test-token'
    end
    provider.instance_variable_set(:@connection, connection)
  end

  it 'exposes default_settings with the new base contract shape' do
    settings = described_class.default_settings
    instance = settings.dig(:instances, :default)

    expect(settings[:enabled]).to be true
    expect(settings[:provider_family]).to eq(:vertex)
    expect(instance.dig(:provider, :location)).to eq('us-central1')
    expect(instance[:transport]).to eq(:http)
    expect(instance.dig(:fleet, :respond_to_requests)).to be(false)
  end

  it 'exposes project and location aware endpoint helpers' do
    expect(provider.api_base).to eq('https://us-central1-aiplatform.googleapis.com/v1')
    expect(provider.generate_content_url(model: 'gemini-2.5-flash')).to eq(vertex_url('google', 'gemini-2.5-flash',
                                                                                      'generateContent'))
    expect(provider.stream_generate_content_url(model: 'gemini-2.5-flash'))
      .to eq("#{vertex_url('google', 'gemini-2.5-flash', 'streamGenerateContent')}?alt=sse")
    expect(provider.embedding_url(model: 'gemini-embedding-001')).to eq(vertex_url('google', 'gemini-embedding-001',
                                                                                   'predict'))
  end

  it 'returns Model::Info objects from list_models with capabilities from STATIC_MODELS' do
    models = provider.list_models

    expect(models.size).to eq(described_class::Provider::STATIC_MODELS.size)
    flash = models.find { |m| m.id == 'gemini-2.5-flash' }
    expect(flash).to be_a(Legion::Extensions::Llm::Model::Info)
    expect(flash.provider).to eq(:vertex)
    expect(flash.family).to eq('gemini')
    expect(flash.name).to eq('gemini-flash')
    expect(flash.capabilities).to include(:chat)

    embed = models.find { |m| m.id == 'gemini-embedding-001' }
    expect(embed.capabilities).to include(:embedding)
  end

  describe '#discover_offerings (0.8.0 registry read path)' do
    let(:model) { 'projects/test-project/locations/us-central1/publishers/google/models/gemini-2.5-flash' }

    before do
      registry = Legion::Extensions::Llm::Inventory::Registry
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vertex, instance_id: 'default'
      )
      registry.reset!
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      token = registry.claim_instance(instance_key: key, callable: Object.new,
                                      probe_request_handle: coordinator)
      probe = registry.readiness_probe_started(instance_key: key, publisher_token: token)
      registry.activate_instance_snapshot(
        publisher_token: token, instance_key: key,
        offerings: [build_read_path_draft(model)], sequence: 0, probe_token: probe
      )
    end

    after { Legion::Extensions::Llm::Inventory::Registry.reset! }

    it 'serves the activated inventory offerings for the instance (07 C5)' do
      offerings = provider.discover_offerings

      expect(offerings.map(&:model)).to eq([model])
    end

    it 'filters by model' do
      expect(provider.discover_offerings(model:).map(&:model)).to eq([model])
      expect(provider.discover_offerings(model: 'projects/x/locations/y/publishers/google/models/other')).to be_empty
    end

    def build_read_path_draft(model)
      now = Time.now.freeze
      ops = Legion::Extensions::Llm::Taxonomies::OPERATIONS.to_h do |operation|
        [operation, Legion::Extensions::Llm::Inventory::OperationEvidence.new(
          operation: operation, status: :supported, source: :provider_implementation, observed_at: now
        )]
      end
      unknown = -> { Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent) }

      Legion::Extensions::Llm::Inventory::OfferingDraft.new(
        provider_native_key: 'gemini-2.5-flash', model: model, tier: :cloud,
        operation_evidence: ops, capability_evidence: {},
        context_evidence: unknown.call, max_output_evidence: unknown.call,
        embedding_dimensions_evidence: unknown.call, model_revision_evidence: unknown.call,
        tokenizer_evidence: unknown.call, quota_domains: {}, metadata: { raw_model: 'gemini-2.5-flash' },
        publication_source: :provider_static_catalog
      )
    end
  end

  it 'reports non-live health without Vertex calls' do
    expect(provider.health(live: false)).to include(provider: :vertex, ready: true, checked: false,
                                                    project: 'test-project', location: 'us-central1')
    expect(connection.gets).to be_empty
  end

  it 'returns readiness metadata including health status' do
    readiness = provider.readiness(live: true)

    expect(readiness).to include(provider: :vertex, ready: true, live: true, local: false, remote: true)
  end

  it 'renders generateContent requests and parses canonical assistant responses' do
    result = provider.chat([message], model: 'gemini-2.5-flash',
                                      params: canonical::Params.build(temperature: 0.2))

    expect(connection.posts.first).to eq(
      [
        vertex_url('google', 'gemini-2.5-flash', 'generateContent'),
        {
          contents: [{ role: 'user', parts: [{ text: 'hello' }] }],
          generationConfig: { temperature: 0.2 }
        }
      ]
    )
    expect(result).to be_a(canonical::Response)
    expect([result.text, result.stop_reason, result.model]).to eq(['done', :end_turn, 'gemini-2.5-flash'])
    expect([result.usage.input_tokens, result.usage.output_tokens]).to eq([3, 5])
  end

  it 'renders rawPredict-style partner requests without inventing provider-specific endpoints' do
    result = provider.chat([message], model: 'mistral-medium',
                                      params: canonical::Params.build(max_tokens: 64))

    expect(connection.posts.first).to eq(
      [
        vertex_url('mistralai', 'mistral-medium-3', 'rawPredict'),
        { model: 'mistral-medium-3', messages: [{ role: 'user', content: 'hello' }], max_tokens: 64, stream: false }
      ]
    )
    expect(result).to be_a(canonical::Response)
    expect([result.text, result.model]).to eq(['raw done', 'mistral-medium-3'])
    expect([result.usage.input_tokens, result.usage.output_tokens]).to eq([2, 4])
  end

  it 'counts tokens through the Vertex countTokens publisher model shape' do
    result = provider.count_tokens(messages: [message], model: 'gemini-2.5-flash')

    expect(connection.posts.first).to eq(
      [
        vertex_url('google', 'gemini-2.5-flash', 'countTokens'),
        { contents: [{ role: 'user', parts: [{ text: 'hello' }] }] }
      ]
    )
    expect(result).to eq(7)
  end

  it 'fails loud for token counting on non-generateContent partner models' do
    expect do
      provider.count_tokens(messages: [message], model: 'mistral-medium')
    end.to raise_error(NotImplementedError, /not standardized/)
    expect(connection.posts).to be_empty
  end

  it 'embeds through documented Vertex text embedding predict shape' do
    embedding = provider.embed(text: 'hello', model: 'gemini-embedding', dimensions: 256,
                               task_type: 'RETRIEVAL_QUERY')

    expect(connection.posts.first).to eq(
      [
        vertex_url('google', 'gemini-embedding-001', 'predict'),
        {
          instances: [{ content: 'hello', task_type: 'RETRIEVAL_QUERY' }],
          parameters: { outputDimensionality: 256 }
        }
      ]
    )
    # 05 §3 documented artifact: { text:, model:, embedding:, usage: }
    expect(embedding[:text]).to eq('hello')
    expect(embedding[:model]).to eq('gemini-embedding-001')
    expect(embedding[:embedding]).to eq([0.1, 0.2])
    expect(embedding[:usage]).to be_a(canonical::Usage)
    expect(embedding[:usage].input_tokens).to eq(4)
  end

  it 'does not invent an embedding body for non-embedding models' do
    expect do
      provider.embed(text: 'hello', model: 'gemini-2.5-flash')
    end.to raise_error(NotImplementedError, /not standardized/)
  end

  describe '.discover_instances' do
    before do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting).and_return(nil)
    end

    it 'returns an empty hash when no settings are configured' do
      expect(described_class.discover_instances).to eq({})
    end

    it 'discovers a :settings instance when project and access_token are present' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :vertex)
        .and_return({ project: 'my-project', access_token: 'tok-123', location: 'us-east1' })

      instances = described_class.discover_instances

      expect(instances[:settings]).to include(vertex_project: 'my-project',
                                              vertex_access_token: 'tok-123',
                                              vertex_location: 'us-east1',
                                              tier: :cloud)
    end

    it 'discovers a :settings instance when project and credentials are present' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :vertex)
        .and_return({ project: 'my-project', credentials: '/path/to/sa.json' })

      instances = described_class.discover_instances

      expect(instances[:settings]).to include(vertex_project: 'my-project',
                                              vertex_credentials: '/path/to/sa.json',
                                              tier: :cloud)
    end

    it 'skips the default instance when project is missing' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :vertex)
        .and_return({ access_token: 'tok-123' })

      expect(described_class.discover_instances).not_to have_key(:settings)
    end

    it 'skips the default instance when no credentials are provided' do
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :vertex)
        .and_return({ project: 'my-project' })

      expect(described_class.discover_instances).not_to have_key(:settings)
    end

    it 'discovers named instances from the instances sub-key' do
      cfg = { instances: { prod: { project: 'prod-proj', access_token: 'tok-prod' } } }
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :vertex).and_return(cfg)

      instances = described_class.discover_instances

      expect(instances[:prod]).to include(vertex_project: 'prod-proj',
                                          vertex_access_token: 'tok-prod',
                                          tier: :cloud)
    end

    it 'normalizes endpoint aliases and model aliases' do
      cfg = { project: 'my-project', access_token: 'tok-123', base_url: 'https://vertex.example/v1',
              model_aliases: { flash: 'gemini-2.5-flash' } }
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :vertex).and_return(cfg)

      expect(described_class.discover_instances[:settings]).to include(
        vertex_project: 'my-project',
        vertex_access_token: 'tok-123',
        vertex_api_base: 'https://vertex.example/v1',
        vertex_model_aliases: { flash: 'gemini-2.5-flash' }
      )
    end

    it 'skips named instances without valid credentials' do
      cfg = { instances: { bad: { project: 'proj' } } }
      allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
        .with(:extensions, :llm, :vertex).and_return(cfg)

      expect(described_class.discover_instances).not_to have_key(:bad)
    end
  end

  def vertex_url(publisher, model, action)
    "#{resource_name(publisher, model)}:#{action}"
  end

  def resource_name(publisher, model)
    "projects/test-project/locations/us-central1/publishers/#{publisher}/models/#{model}"
  end
end
