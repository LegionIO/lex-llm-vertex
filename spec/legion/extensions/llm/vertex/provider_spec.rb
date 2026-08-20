# frozen_string_literal: true

require 'spec_helper'

# Capability policy cascade for Vertex offerings. The writer's OfferingDraft
# capability evidence is resolved through the shared CapabilityPolicy; these
# examples drive the provider's policy resolver directly (the legacy
# offering-production entry is gone in 0.8.0 — 07 C5).
RSpec.describe Legion::Extensions::Llm::Vertex::Provider do
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

  def capability_policy(metadata: {}, instance_id: :default)
    provider.send(
      :resolve_capability_policy, 'gemini-2.5-flash',
      api: :generate_content, metadata: metadata, instance_id: instance_id
    )
  end

  describe 'model with no feature metadata' do
    it 'defaults optional capabilities to false' do
      policy = capability_policy

      expect(policy[:sources][:thinking]).to include(value: false, source: :default_false)
    end
  end

  describe 'model with provider catalog heuristics' do
    it 'reports tools and vision as :provider_catalog for generateContent models' do
      policy = capability_policy

      expect(policy[:sources][:tools]).to include(value: true, source: :provider_catalog)
      expect(policy[:sources][:vision]).to include(value: true, source: :provider_catalog)
      expect(policy[:sources][:streaming]).to include(value: true, source: :provider_catalog)
    end
  end

  describe 'model with real Vertex feature metadata' do
    it 'reports capabilities as :model_metadata when supportedFeatures is present' do
      metadata = { supportedFeatures: { 'functionCalling' => true, 'multimodalInput' => true, 'thinking' => true } }
      policy = capability_policy(metadata:)

      expect(policy[:sources][:tools]).to include(value: true, source: :model_metadata)
      expect(policy[:sources][:vision]).to include(value: true, source: :model_metadata)
      expect(policy[:sources][:thinking]).to include(value: true, source: :model_metadata)
    end
  end

  describe 'provider-root override' do
    let(:base_config) do
      { project: 'test-project', access_token: 'test-token', tools_flag: false, vision_flag: false }
    end

    it 'applies provider overrides with :provider_override source' do
      policy = capability_policy

      expect(policy[:sources][:tools]).to include(value: false, source: :provider_override)
      expect(policy[:sources][:vision]).to include(value: false, source: :provider_override)
      expect(policy[:capabilities]).not_to include(:tools)
      expect(policy[:capabilities]).not_to include(:vision)
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
      policy = capability_policy(instance_id: :default)

      expect(policy[:sources][:tools]).to include(value: true, source: :instance_override)
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
      policy = capability_policy

      expect(policy[:sources][:tools]).to include(value: false, source: :model_override)
      expect(policy[:sources][:thinking]).to include(value: true, source: :model_override)
      expect(policy[:capabilities]).not_to include(:tools)
      expect(policy[:capabilities]).to include(:thinking)
    end
  end
end
