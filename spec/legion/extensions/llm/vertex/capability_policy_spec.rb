# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Vertex::Provider do # rubocop:disable RSpec/SpecFilePathFormat
  let(:provider) { described_class.new(Legion::Extensions::Llm.config) }
  let(:base_config) { { project: 'test-project', access_token: 'test-token' } }

  before do
    Legion::Extensions::Llm.configure do |config|
      config.vertex_project = 'test-project'
      config.vertex_location = 'us-central1'
      config.vertex_access_token = 'test-token'
    end
    allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
      .with(:extensions, :llm, :vertex).and_return(base_config)
  end

  describe 'model with no feature metadata' do
    it 'defaults optional capabilities to false' do
      offering = provider.offering_for(model: 'gemini-2.5-flash', model_family: :gemini)

      sources = offering.capability_sources
      expect(sources[:thinking]).to include(value: false, source: :default_false)
    end
  end

  describe 'model with provider catalog heuristics' do
    it 'reports tools and vision as :provider_catalog for generateContent models' do
      offering = provider.offering_for(model: 'gemini-2.5-flash', model_family: :gemini)

      sources = offering.capability_sources
      expect(sources[:tools]).to include(value: true, source: :provider_catalog)
      expect(sources[:vision]).to include(value: true, source: :provider_catalog)
      expect(sources[:streaming]).to include(value: true, source: :provider_catalog)
    end
  end

  describe 'model with real Vertex feature metadata' do
    it 'reports capabilities as :model_metadata when supportedFeatures is present' do
      metadata = { supportedFeatures: { 'functionCalling' => true, 'multimodalInput' => true, 'thinking' => true } }
      offering = provider.offering_for(model: 'gemini-2.5-flash', model_family: :gemini, **metadata)

      sources = offering.capability_sources
      expect(sources[:tools]).to include(value: true, source: :model_metadata)
      expect(sources[:vision]).to include(value: true, source: :model_metadata)
      expect(sources[:thinking]).to include(value: true, source: :model_metadata)
    end
  end

  describe 'provider-root override' do
    let(:base_config) do
      { project: 'test-project', access_token: 'test-token', tools_flag: false, vision_flag: false }
    end

    it 'applies provider overrides with :provider_override source' do
      offering = provider.offering_for(model: 'gemini-2.5-flash', model_family: :gemini)

      sources = offering.capability_sources
      expect(sources[:tools]).to include(value: false, source: :provider_override)
      expect(sources[:vision]).to include(value: false, source: :provider_override)
      expect(offering.capabilities).not_to include(:tools)
      expect(offering.capabilities).not_to include(:vision)
    end
  end

  describe 'instance override' do
    let(:base_config) do
      {
        project: 'test-project', access_token: 'test-token',
        instances: { default: { tools_flag: true } }
      }
    end

    it 'applies instance overrides with :instance_override source' do
      offering = provider.offering_for(model: 'gemini-2.5-flash', model_family: :gemini, instance_id: :default)

      sources = offering.capability_sources
      expect(sources[:tools]).to include(value: true, source: :instance_override)
    end
  end

  describe 'model override' do
    let(:base_config) do
      {
        project: 'test-project', access_token: 'test-token',
        models: { 'gemini-2.5-flash': { tools_flag: false, thinking_flag: true } }
      }
    end

    it 'applies model overrides with :model_override source' do
      offering = provider.offering_for(model: 'gemini-2.5-flash', model_family: :gemini)

      sources = offering.capability_sources
      expect(sources[:tools]).to include(value: false, source: :model_override)
      expect(sources[:thinking]).to include(value: true, source: :model_override)
      expect(offering.capabilities).not_to include(:tools)
      expect(offering.capabilities).to include(:thinking)
    end
  end
end
