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

    generate_content_response
  end

  def generate_content_response
    {
      'modelVersion' => 'gemini-2.5-flash',
      'candidates' => [{ 'content' => { 'parts' => [{ 'text' => 'done' }] } }],
      'usageMetadata' => { 'promptTokenCount' => 3, 'candidatesTokenCount' => 5 }
    }
  end

  def raw_predict_response
    {
      'model' => 'mistral-medium-3',
      'choices' => [{ 'message' => { 'content' => 'raw done' } }],
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
  let(:provider) { described_class::Provider.new(Legion::Extensions::Llm.config) }
  let(:connection) { FakeVertexConnection.new }
  let(:message) { Legion::Extensions::Llm::Message.new(role: :user, content: 'hello') }
  let(:model) { Legion::Extensions::Llm::Model::Info.new(id: 'gemini-2.5-flash', provider: :vertex) }
  let(:registry_publisher) { instance_double(Legion::Extensions::Llm::RegistryPublisher) }

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

    expect(settings[:enabled]).to be false
    expect(settings[:default_model]).to be_nil
    expect(settings[:location]).to eq('us-central1')
    expect(settings[:model_whitelist]).to eq([])
    expect(settings[:model_blacklist]).to eq([])
    expect(settings[:model_cache_ttl]).to eq(3600)
    expect(settings[:tls]).to include(enabled: false)
    expect(settings[:instances]).to eq({})
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
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(registry_publisher).to receive(:publish_models_async)
    allow(registry_publisher).to receive(:publish_readiness_async)

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

    expect(registry_publisher).to have_received(:publish_models_async)
      .with(models, readiness: hash_including(provider: :vertex))
  end

  it 'uses the base RegistryPublisher from lex-llm' do
    publisher = described_class::Provider.registry_publisher
    expect(publisher).to be_a(Legion::Extensions::Llm::RegistryPublisher)
    expect(publisher.provider_family).to eq(:vertex)
  end

  it 'maps offline offerings with Vertex family, model family, and instance location metadata' do
    offerings = provider.discover_offerings(live: false)
    gemini = offerings.find { |offering| offering.metadata[:alias] == 'gemini-flash' }
    mistral = offerings.find { |offering| offering.metadata[:model_family] == :mistral }
    embed = offerings.find(&:embedding?)

    expect(gemini.to_h).to include(provider_family: :vertex, instance_id: :default)
    expect(gemini.model).to eq(resource_name('google', 'gemini-2.5-flash'))
    expect(gemini.metadata).to include(model_family: :gemini, project: 'test-project', location: 'us-central1')
    expect(mistral.model).to eq(resource_name('mistralai', 'mistral-medium-3'))
    expect(embed.usage_type).to eq(:embedding)
  end

  it 'accepts canonical aliases and explicit model families for offerings' do
    offering = provider.offering_for(model: 'gemini-flash', model_family: :gemini, instance_id: :central)

    expect(offering.to_h).to include(provider_family: :vertex, instance_id: :central,
                                     model: resource_name('google', 'gemini-2.5-flash'))
    expect(offering.metadata).to include(model_family: :gemini, alias: 'gemini-flash')
  end

  it 'preserves full Vertex resource names supplied by callers' do
    resource = resource_name('anthropic', 'claude-sonnet-4-5')
    offering = provider.offering_for(model: resource, model_family: :anthropic)

    expect(offering.model).to eq(resource)
    expect(offering.metadata).to include(model_family: :anthropic, publisher: 'anthropic', api: :raw_predict)
  end

  it 'reports non-live health without Vertex calls' do
    expect(provider.health(live: false)).to include(provider: :vertex, ready: true, checked: false,
                                                    project: 'test-project', location: 'us-central1')
    expect(connection.gets).to be_empty
  end

  it 'builds live offerings from publisher model listings and publishes Model::Info' do
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(registry_publisher).to receive(:publish_models_async)
    allow(registry_publisher).to receive(:publish_readiness_async)

    offerings = provider.discover_offerings(live: true)

    expect(connection.gets).to eq(['projects/test-project/locations/us-central1/publishers/google/models'])
    expect(offerings.first.model).to eq(resource_name('google', 'gemini-2.5-flash'))
    expect(registry_publisher).to have_received(:publish_models_async)
      .with(array_including(an_object_having_attributes(id: resource_name('google', 'gemini-2.5-flash'))),
            readiness: hash_including(provider: :vertex, live: false))
  end

  it 'publishes live readiness metadata asynchronously through the registry publisher' do
    allow(described_class::Provider).to receive(:registry_publisher).and_return(registry_publisher)
    allow(registry_publisher).to receive(:publish_readiness_async)

    readiness = provider.readiness(live: true)

    expect(registry_publisher).to have_received(:publish_readiness_async).with(readiness)
  end

  it 'renders generateContent requests and parses assistant responses' do
    result = provider.chat([message], model: model, temperature: 0.2)

    expect(connection.posts.first).to eq(
      [
        vertex_url('google', 'gemini-2.5-flash', 'generateContent'),
        {
          contents: [{ role: 'user', parts: [{ text: 'hello' }] }],
          generationConfig: { temperature: 0.2 }
        }
      ]
    )
    expect([result.content, result.input_tokens, result.output_tokens]).to eq(['done', 3, 5])
  end

  it 'renders rawPredict-style partner requests without inventing provider-specific endpoints' do
    result = provider.chat([message], model: 'mistral-medium', max_tokens: 64)

    expect(connection.posts.first).to eq(
      [
        vertex_url('mistralai', 'mistral-medium-3', 'rawPredict'),
        { model: 'mistral-medium-3', messages: [{ role: 'user', content: 'hello' }], max_tokens: 64, stream: false }
      ]
    )
    expect([result.content, result.input_tokens, result.output_tokens]).to eq(['raw done', 2, 4])
  end

  it 'counts tokens through the Vertex countTokens publisher model shape' do
    result = provider.count_tokens([message], model: model)

    expect(connection.posts.first).to eq(
      [
        vertex_url('google', 'gemini-2.5-flash', 'countTokens'),
        { contents: [{ role: 'user', parts: [{ text: 'hello' }] }] }
      ]
    )
    expect(result).to include(input_tokens: 7)
  end

  it 'returns token-counting metadata for non-generateContent partner models' do
    result = provider.count_tokens([message], model: 'mistral-medium')

    expect(result).to include(supported: false, provider: :vertex, reason: /countTokens/)
    expect(connection.posts).to be_empty
  end

  it 'embeds through documented Vertex text embedding predict shape' do
    embedding = provider.embed('hello', model: 'gemini-embedding', dimensions: 256, task_type: 'RETRIEVAL_QUERY')

    expect(connection.posts.first).to eq(
      [
        vertex_url('google', 'gemini-embedding-001', 'predict'),
        {
          instances: [{ content: 'hello', task_type: 'RETRIEVAL_QUERY' }],
          parameters: { outputDimensionality: 256 }
        }
      ]
    )
    expect([embedding.vectors, embedding.input_tokens]).to eq([[0.1, 0.2], 4])
  end

  it 'does not invent an embedding body for non-embedding models' do
    expect do
      provider.embed('hello', model: 'gemini-2.5-flash')
    end.to raise_error(NotImplementedError, /not standardized/)
  end

  def vertex_url(publisher, model, action)
    "#{resource_name(publisher, model)}:#{action}"
  end

  def resource_name(publisher, model)
    "projects/test-project/locations/us-central1/publishers/#{publisher}/models/#{model}"
  end
end
