# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'digest'
require 'uri'

require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'
require 'legion/extensions/llm/fleet/worker_execution'
require 'legion/extensions/llm/fleet/protocol'

# Stub the actor runtime so the DiscoveryRefresh class can be loaded in test.
module Legion
  module Extensions
    module Actors
      unless const_defined?(:Every, false)
        # Stub base class for discovery actor loading in test context
        class Every
          def self.every_seconds = 3600
        end
      end
    end

    module Helpers
      module Lex; end unless const_defined?(:Lex, false)
    end
  end
end

require 'legion/extensions/llm/vertex/callable'

# Test-local callable that extends VertexCallable with dispatch operations
# required by FleetWorkerExecution. Tracks inference call count for
# conformance assertions.
class TrackingVertexCallable < Legion::Extensions::Llm::Vertex::Actor::VertexCallable
  attr_reader :call_count

  def initialize(instance_cfg:, logger:)
    super
    @call_count = 0
  end

  def chat(model:, **)
    @call_count += 1
    { role: 'assistant', content: 'test response', model: model }
  end

  def stream_chat(model:, **)
    @call_count += 1
    { role: 'assistant', content: 'streamed response', model: model }
  end

  def embed(model:, **)
    @call_count += 1
    { embedding: [0.1, 0.2, 0.3], model: model }
  end

  def count_tokens(model:, **)
    @call_count += 1
    { token_count: 42, model: model }
  end
end

# Evidence-building helpers for the SSOT v3 conformance harness.
# Extracted to keep VertexSsotHarness within class length limits.
module VertexSsotEvidenceHelpers
  private

  def build_operation_evidence(now:, is_embedding:)
    if is_embedding
      {
        chat: op_evidence(:chat, :unsupported, now),
        stream_chat: op_evidence(:stream_chat, :unsupported, now),
        embed: op_evidence(:embed, :supported, now),
        image: op_evidence(:image, :unsupported, now),
        transcribe: op_evidence(:transcribe, :unsupported, now),
        translate: op_evidence(:translate, :unsupported, now),
        speak: op_evidence(:speak, :unsupported, now),
        moderate: op_evidence(:moderate, :unsupported, now),
        count_tokens: op_evidence(:count_tokens, :unsupported, now)
      }
    else
      {
        chat: op_evidence(:chat, :supported, now),
        stream_chat: op_evidence(:stream_chat, :supported, now),
        embed: op_evidence(:embed, :unsupported, now),
        image: op_evidence(:image, :unsupported, now),
        transcribe: op_evidence(:transcribe, :unsupported, now),
        translate: op_evidence(:translate, :unsupported, now),
        speak: op_evidence(:speak, :unsupported, now),
        moderate: op_evidence(:moderate, :unsupported, now),
        count_tokens: op_evidence(:count_tokens, :supported, now)
      }
    end
  end

  def op_evidence(operation, status, observed_at)
    source = status == :unknown ? :default_false : :provider_implementation
    Legion::Extensions::Llm::Inventory::OperationEvidence.new(
      operation: operation, status: status, source: source, observed_at: observed_at
    )
  end

  def build_capability_evidence
    {
      completion: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :completion, status: :supported, source: :provider_implementation, observed_at: Time.now
      ),
      streaming: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :streaming, status: :supported, source: :provider_implementation, observed_at: Time.now
      ),
      tools: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :tools, status: :unknown, source: :default_false, observed_at: Time.now
      ),
      thinking: Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
        capability: :thinking, status: :unknown, source: :default_false, observed_at: Time.now
      )
    }
  end

  def model_not_ready_signal?(error:)
    return false unless error.respond_to?(:response) && error.response.is_a?(Hash)

    body = error.response[:body].to_s.downcase
    body.include?('model not ready') || body.include?('model_not_ready')
  end
end

# Harness class for Vertex SSOT v3 conformance testing. Implements the full
# interface required by the shared conformance examples without touching
# any external service. Defined inline per the conformance kit contract.
class VertexSsotHarness
  include VertexSsotEvidenceHelpers

  INSTANCE_CONFIGS = [
    {
      vertex_project: 'my-project-alpha',
      vertex_location: 'us-central1',
      vertex_access_token: 'ya29.test-token-alpha',
      tier: :cloud
    }.freeze,
    {
      vertex_project: 'my-project-beta',
      vertex_location: 'europe-west4',
      vertex_access_token: 'ya29.test-token-beta',
      tier: :cloud
    }.freeze
  ].freeze

  def provider_family = :vertex
  def instance_configs = INSTANCE_CONFIGS

  def instance_id(instance_config:)
    project = instance_config[:vertex_project] || instance_config[:project] || 'unknown'
    location = instance_config[:vertex_location] || instance_config[:location] || 'us-central1'
    fingerprint = credential_fingerprint(instance_config: instance_config)
    "#{project}:#{location}/#{fingerprint}"
  end

  def build_callable(instance_config:)
    TrackingVertexCallable.new(instance_cfg: instance_config, logger: Logger.new(File::NULL))
  end

  def build_offering_drafts(tier: :cloud, **)
    now = Time.now.freeze
    model_id = 'gemini-2.5-flash'
    [build_single_offering(model_id: model_id, tier: tier, now: now)]
  end

  def safe_readiness(**)
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true,
      reason: 'Vertex models-list returned 200',
      metadata: { status: 200, base_url: 'https://us-central1-aiplatform.googleapis.com' }
    )
  end

  def inference_call_count(callable:)
    callable.respond_to?(:call_count) ? callable.call_count : 0
  end

  def normalize_dispatch_error(error:)
    callable = build_callable(instance_config: instance_configs.first)
    outcome = callable.normalize_dispatch_error(error: error)
    apply_vertex_escalation(outcome: outcome, error: error)
  end

  # Returns a Vertex explicit flat SERVICE_UNAVAILABLE response.
  # This is the only signal that correctly maps to :instance_unavailable per §8.
  def instance_unavailable_error
    response = {
      status: 503,
      headers: {},
      body: '{"error": {"status": "SERVICE_UNAVAILABLE", "message": "The service is unavailable"}}'
    }
    Faraday::ServerError.new('the server responded with status 503', response)
  end

  def overloaded_error
    response = { status: 503, headers: {}, body: '{"error": {"code": 503, "message": "Server overloaded"}}' }
    Faraday::ServerError.new('the server responded with status 503', response)
  end

  def model_not_ready_error
    response = { status: 503, headers: {}, body: '{"error": {"code": 503, "message": "Model not ready"}}' }
    Faraday::ServerError.new('the server responded with status 503 - model not ready', response)
  end

  private

  def credential_fingerprint(instance_config:)
    token = instance_config[:vertex_access_token] || instance_config[:access_token]
    creds = instance_config[:vertex_credentials] || instance_config[:credentials]
    material = (token || creds).to_s
    return 'no-cred' if material.empty?

    ::Digest::SHA256.hexdigest(material)[0, 6]
  end

  # §8 firewall: only the overloaded→model_not_ready refinement is applied here.
  # connection_failure, timeout, generic 5xx, and all other transient errors are
  # never promoted to instance_unavailable — they remain request-local.
  def apply_vertex_escalation(outcome:, error:)
    if outcome.kind == :overloaded && model_not_ready_signal?(error: error)
      return Legion::Extensions::Llm::Routing::ProviderOutcome.new(
        kind: :model_not_ready, reason: outcome.reason
      )
    end

    outcome
  end

  def build_single_offering(model_id:, tier:, now:)
    Legion::Extensions::Llm::Inventory::OfferingDraft.new(
      provider_native_key: model_id, model: model_id, tier: tier,
      operation_evidence: build_operation_evidence(now: now, is_embedding: false),
      capability_evidence: build_capability_evidence,
      context_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      max_output_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
      embedding_dimensions_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      model_revision_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(
        status: :unknown, source: :absent
      ),
      tokenizer_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
      quota_domains: {}, metadata: { raw_model: model_id }, publication_source: :provider_static_catalog
    )
  end
end

RSpec.describe Legion::Extensions::Llm::Vertex do
  let(:ssot_harness) { VertexSsotHarness.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }

  before { registry.reset! }

  it_behaves_like 'an SSOT v3 provider adapter'

  # --- Vertex-specific instance identity derivation ---------------------------

  describe 'instance identity derivation' do
    it 'derives instance_id as project:location/fingerprint' do
      config = { vertex_project: 'my-project', vertex_location: 'us-central1', vertex_access_token: 'ya29.token' }
      fingerprint = Digest::SHA256.hexdigest('ya29.token')[0, 6]
      expect(ssot_harness.instance_id(instance_config: config)).to eq("my-project:us-central1/#{fingerprint}")
    end

    it 'produces distinct instance IDs for two different project/location combos' do
      ids = ssot_harness.instance_configs.map { |cfg| ssot_harness.instance_id(instance_config: cfg) }
      expect(ids.uniq.size).to eq(2)
    end

    it 'reproduces the same instance_id across multiple calls (stable identity)' do
      config = ssot_harness.instance_configs.first
      id_a = ssot_harness.instance_id(instance_config: config)
      id_b = ssot_harness.instance_id(instance_config: config)
      expect(id_a).to eq(id_b)
    end

    it 'uses no-cred fingerprint when no credentials present' do
      config = { vertex_project: 'proj', vertex_location: 'us-east1' }
      expect(ssot_harness.instance_id(instance_config: config)).to eq('proj:us-east1/no-cred')
    end
  end

  # --- Two projects with same model = separate lanes --------------------------

  describe 'two Vertex projects serving the same model' do
    def bring_up_instance(config, tier: :cloud)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vertex)
      instance_id = ssot_harness.instance_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vertex, instance_id: instance_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe
      )

      { publisher: publisher, key: key, callable: callable, token: token, drafts: drafts, coordinator: coordinator }
    end

    it 'creates separate lanes for the same model on different instances' do
      a = bring_up_instance(ssot_harness.instance_configs[0])
      b = bring_up_instance(ssot_harness.instance_configs[1])

      snapshot = registry.snapshot
      lanes_a = snapshot.lanes_for(instance_key: a[:key])
      lanes_b = snapshot.lanes_for(instance_key: b[:key])

      expect(lanes_a).not_to be_empty
      expect(lanes_b).not_to be_empty

      lane_ids_a = lanes_a.map(&:lane_id)
      lane_ids_b = lanes_b.map(&:lane_id)
      expect(lane_ids_a & lane_ids_b).to be_empty
    end

    it 'reproduces IDs after restart (identity is deterministic from inputs)' do
      config = ssot_harness.instance_configs[0]
      first_run = bring_up_instance(config)
      first_offering_id = registry.snapshot.offerings_for(instance_key: first_run[:key]).first.offering_id
      first_lane_id = registry.snapshot.lanes_for(instance_key: first_run[:key]).first.lane_id

      registry.reset!
      second_run = bring_up_instance(config)
      second_offering_id = registry.snapshot.offerings_for(instance_key: second_run[:key]).first.offering_id
      second_lane_id = registry.snapshot.lanes_for(instance_key: second_run[:key]).first.lane_id

      expect(second_offering_id).to eq(first_offering_id)
      expect(second_lane_id).to eq(first_lane_id)
    end
  end

  # --- Error normalization ----------------------------------------------------

  describe 'error normalization' do
    # §8 firewall: only an explicit flat SERVICE_UNAVAILABLE response maps to instance_unavailable
    it 'classifies explicit SERVICE_UNAVAILABLE response as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.instance_unavailable_error)
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to eq(:instance_unavailable)
    end

    # §8 firewall: connection_failure is request-local/terminal; never promotes to instance_unavailable
    it 'classifies connection failure as connection_failure, never as instance_unavailable' do
      conn_error = Faraday::ConnectionFailed.new(
        'Connection refused - connect(2) for us-central1-aiplatform.googleapis.com:443'
      )
      outcome = ssot_harness.normalize_dispatch_error(error: conn_error)
      expect(outcome.kind).to eq(:connection_failure)
      expect(outcome.kind).not_to eq(:instance_unavailable),
                                  '§8: connection_failure must never promote to instance_unavailable'
    end

    it 'classifies 503 as overloaded, never as instance_unavailable' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.overloaded_error)
      expect(outcome.kind).to eq(:overloaded)
      expect(outcome.kind).not_to eq(:instance_unavailable)
    end

    it 'classifies model-not-ready as model_not_ready' do
      outcome = ssot_harness.normalize_dispatch_error(error: ssot_harness.model_not_ready_error)
      expect(outcome.kind).to eq(:model_not_ready)
    end

    it 'never returns instance_unavailable from the callable for any server error' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      [500, 502, 503, 504, 529].each do |status|
        response = { status: status, headers: {}, body: '' }
        error = Faraday::ServerError.new(status.to_s, response)
        outcome = callable.normalize_dispatch_error(error: error)
        expect(outcome.kind).not_to eq(:instance_unavailable),
                                    "status #{status} should not map to instance_unavailable"
      end
    end

    it 'classifies 429 as rate_limited' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      response = { status: 429, headers: {}, body: '' }
      error = Faraday::ClientError.new('429', response)
      outcome = callable.normalize_dispatch_error(error: error)
      expect(outcome.kind).to eq(:rate_limited)
    end
  end

  # --- Startup gating ---------------------------------------------------------

  describe 'startup gating' do
    let(:instance_id) { ssot_harness.instance_id(instance_config: ssot_harness.instance_configs[0]) }
    let(:key) do
      Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vertex, instance_id: instance_id
      )
    end
    let(:publisher) { Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vertex) }

    it 'remains initializing until readiness probe succeeds' do
      cfg = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: cfg)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end

    it 'stays initializing after an initial readiness failure' do
      cfg = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: cfg)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )
      token = publisher.claim_instance(instance_id: instance_id, callable: callable, probe_request_handle: coordinator)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token)
      publisher.readiness_failed(instance_id: instance_id, probe_token: probe,
                                 reason: 'Vertex models-list connection failed')

      snapshot = registry.snapshot
      expect(snapshot.instance(instance_key: key)).to be_nil
      expect(snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end
  end

  # --- VertexCallable direct contract -----------------------------------------

  describe Legion::Extensions::Llm::Vertex::Actor::VertexCallable do
    let(:callable) do
      described_class.new(
        instance_cfg: ssot_harness.instance_configs[0],
        logger: Logger.new(File::NULL)
      )
    end

    it 'responds to disconnect' do
      expect(callable).to respond_to(:disconnect)
      expect(callable).to respond_to(:disconnected?)
    end

    it 'responds to normalize_dispatch_error with kwargs' do
      expect(callable).to respond_to(:normalize_dispatch_error)
    end

    it 'is not disconnected on creation' do
      expect(callable.disconnected?).to be(false)
    end

    it 'becomes disconnected after disconnect' do
      callable.disconnect
      expect(callable.disconnected?).to be(true)
    end

    it 'returns a ProviderOutcome from normalize_dispatch_error' do
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
      expect(outcome.kind).to be_a(Symbol)
      expect(outcome.reason).to be_a(String)
    end
  end

  # --- OfferingDraft structure ------------------------------------------------

  describe 'OfferingDraft structure' do
    let(:config) { ssot_harness.instance_configs[0] }
    let(:callable) { ssot_harness.build_callable(instance_config: config) }
    let(:drafts) { ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: :cloud) }

    it 'produces valid OfferingDraft instances' do
      expect(drafts).to all(be_a(Legion::Extensions::Llm::Inventory::OfferingDraft))
    end

    it 'includes all required operation evidence keys' do
      expected_ops = Legion::Extensions::Llm::Taxonomies::OPERATIONS.sort
      drafts.each do |draft|
        actual_ops = draft.operation_evidence.keys.sort
        expect(actual_ops).to eq(expected_ops)
      end
    end

    it 'sets publication_source to :provider_static_catalog' do
      drafts.each do |draft|
        expect(draft.publication_source).to eq(:provider_static_catalog)
      end
    end

    it 'uses frozen metadata without secret keys' do
      drafts.each do |draft|
        expect(draft.metadata).to be_frozen
        draft.metadata.each_key do |key|
          normalized = key.to_s.downcase.gsub(/[^a-z0-9]/, '')
          expect(normalized).not_to include('credential')
          expect(normalized).not_to include('secret')
          expect(normalized).not_to include('apikey')
        end
      end
    end

    it 'does not declare quota_domains on offerings' do
      drafts.each do |draft|
        expect(draft.quota_domains).to be_empty,
                                       'Vertex offerings must not declare quota_domains without authoritative scope'
      end
    end
  end

  # --- No Legion::LLM reverse dependency -------------------------------------

  describe 'dependency isolation' do
    it 'does not require Legion::LLM (no reverse dependency on top-level llm module)' do
      project_root = File.expand_path('../../../..', __dir__)
      actor_file = File.read(
        File.join(project_root, 'lib/legion/extensions/llm/vertex/actors/discovery_refresh.rb')
      )
      expect(actor_file).not_to match(/\bLegion::LLM\b/)
    end

    it 'VertexCallable does not reference Legion::LLM' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      outcome = callable.normalize_dispatch_error(error: RuntimeError.new('test'))
      expect(outcome).to be_a(Legion::Extensions::Llm::Routing::ProviderOutcome)
    end
  end

  # --- No default model/provider ----------------------------------------------

  describe 'no default model or provider' do
    it 'rejects instance_id "default" as reserved' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :vertex, instance_id: 'default'
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end

    it 'rejects nil instance_id' do
      expect do
        Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
          provider_family: :vertex, instance_id: nil
        )
      end.to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end

    it 'does not define a DEFAULT_MODEL constant' do
      expect(described_class.const_defined?(:DEFAULT_MODEL, false)).to be(false)
    end

    it 'does not define a DEFAULT_PROVIDER constant' do
      expect(described_class.const_defined?(:DEFAULT_PROVIDER, false)).to be(false)
    end
  end

  # --- ReadinessResult contract -----------------------------------------------

  describe 'ReadinessResult contract' do
    it 'safe_readiness returns a ready ReadinessResult' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      result = ssot_harness.safe_readiness(instance_config: config, callable: callable)

      expect(result).to be_a(Legion::Extensions::Llm::Inventory::ReadinessResult)
      expect(result.ready?).to be(true)
      expect(result.reason).to be_a(String)
      expect(result.reason).not_to be_empty
    end

    it 'readiness does not invoke inference on the callable' do
      config = ssot_harness.instance_configs[0]
      callable = ssot_harness.build_callable(instance_config: config)
      ssot_harness.safe_readiness(instance_config: config, callable: callable)
      expect(ssot_harness.inference_call_count(callable: callable)).to eq(0)
    end
  end
end
