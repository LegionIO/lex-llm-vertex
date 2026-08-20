# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'digest'

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
# The actor is required (not just stubbed around) so its real helpers back the
# harness and its manual/shutdown logic is covered.
require 'legion/extensions/llm/vertex/actors/discovery_refresh'

# Builds a genuine Faraday error the way production raises it: a real request
# through the raise_error middleware (the same middleware the provider
# connection installs), so the error carries the adapter-produced response
# shape — never a hand-assembled hash the spec invents.
module VertexSsotFaraday
  module_function

  def error_for(status:, body:)
    connection = Faraday.new do |f|
      f.response :raise_error
      f.adapter :test do |stub|
        stub.post(/.*/) { [status, {}, body] }
      end
    end
    begin
      connection.post('/v1/conformance', {})
      raise "expected Faraday to raise for status #{status}"
    rescue Faraday::ClientError, Faraday::ServerError => e
      e
    end
  end
end

# Records HTTP posts so the callable's REAL Provider render path can be driven
# offline. The harness dispatch stubs intentionally bypass this path; the
# raw-string model examples are what would catch a NoMethodError landmine if
# the render path expected a Model::Info where the fleet passes a raw string.
class VertexSsotFakeConnection
  attr_reader :posts

  def initialize
    @posts = []
  end

  def post(url, payload)
    @posts << [url, payload]
    Struct.new(:body).new(body_for(url))
  end

  def close = nil

  private

  def body_for(url)
    case url
    when /:predict\z/ then { 'predictions' => [{ 'embeddings' => { 'values' => [0.1, 0.2] } }] }
    when /:countTokens\z/ then { 'totalTokens' => 7 }
    else
      # modelVersion echoes the model in the request URL (the Vertex wire
      # does) so the canonical response keeps the Selection-derived model
      # end-to-end (B4).
      {
        'modelVersion' => url[%r{models/([^:]+):}, 1],
        'candidates' => [
          { 'content' => { 'parts' => [{ 'text' => 'done' }] }, 'finishReason' => 'STOP' }
        ],
        'usageMetadata' => { 'promptTokenCount' => 1, 'candidatesTokenCount' => 2 }
      }
    end
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
    body = error.response_body.to_s.downcase
    body.include?('model not ready') || body.include?('model_not_ready')
  end
end

# Harness class for Vertex SSOT v3 conformance testing. Implements the full
# interface required by the shared conformance examples without touching
# any external service. Defined inline per the conformance kit contract.
#
# The harness drives the PRODUCTION callable (VertexCallable) and the actor's
# real identity helpers — no spec-local re-implementation of instance_id or
# credential fingerprinting, and no dispatch stubs on the callable.
class VertexSsotHarness
  include RSpec::Mocks::ExampleMethods
  include VertexSsotEvidenceHelpers

  # Synthetic operator config in the shape of the frozen employee config: the
  # NAME (hash key) is the instance identity the router keys instances.<name>
  # lookups by (SSOT v3 fail-forward); the derived project:location/
  # fingerprint is the secondary physical_id for dedup/diagnostics only.
  NAMED_INSTANCE_CONFIGS = {
    'conformance-alpha' => {
      vertex_project: 'my-project-alpha',
      vertex_location: 'us-central1',
      vertex_access_token: 'ya29.test-token-alpha',
      tier: :cloud
    }.freeze,
    'conformance-beta' => {
      vertex_project: 'my-project-beta',
      vertex_location: 'europe-west4',
      vertex_access_token: 'ya29.test-token-beta',
      tier: :cloud
    }.freeze
  }.freeze

  DISPATCH_OPERATIONS = %i[chat stream_chat embed count_tokens].freeze

  def provider_family = :vertex
  def instance_configs = NAMED_INSTANCE_CONFIGS.values

  def actor
    @actor ||= Legion::Extensions::Llm::Vertex::Actor::DiscoveryRefresh.new
  end

  # The config NAME — the instance identity (the operator's instances.<name>
  # key; the fixture names stand in for operator names).
  def instance_id(instance_config:)
    NAMED_INSTANCE_CONFIGS.key(instance_config)
  end

  # The actor's real secondary physical-id derivation (single source of
  # truth — no duplicated fingerprint/ID logic in the harness).
  def physical_id(instance_config:)
    actor.send(:derive_physical_id, instance_cfg: instance_config)
  end

  # The PRODUCTION callable. Its wrapped Provider's dispatch operations are
  # intercepted (no network) so the fleet contract — callable signature,
  # delegation, kwargs passthrough — is what is under test.
  def build_callable(instance_config:)
    callable = Legion::Extensions::Llm::Vertex::Actor::VertexCallable.new(
      instance_cfg: instance_config, logger: Logger.new(File::NULL)
    )
    @dispatch_counts ||= {}
    @dispatch_counts[callable] = 0
    DISPATCH_OPERATIONS.each do |operation|
      allow(callable.provider).to receive(operation) do |*_args, **_kwargs, &_block|
        @dispatch_counts[callable] += 1
        fake_dispatch_result(operation)
      end
    end
    callable
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
    @dispatch_counts.fetch(callable, 0)
  end

  def normalize_dispatch_error(error:)
    callable = Legion::Extensions::Llm::Vertex::Actor::VertexCallable.new(
      instance_cfg: instance_configs.first, logger: Logger.new(File::NULL)
    )
    outcome = callable.normalize_dispatch_error(error: error)
    apply_vertex_escalation(outcome: outcome, error: error)
  end

  # Real Faraday-raised errors (raise_error middleware round-trip) — the only
  # shapes production produces.
  def instance_unavailable_error
    VertexSsotFaraday.error_for(
      status: 503, body: '{"error": {"status": "SERVICE_UNAVAILABLE", "message": "The service is unavailable"}}'
    )
  end

  def overloaded_error
    VertexSsotFaraday.error_for(status: 503, body: '{"error": {"code": 503, "message": "Server overloaded"}}')
  end

  def model_not_ready_error
    VertexSsotFaraday.error_for(status: 503, body: '{"error": {"code": 503, "message": "Model not ready"}}')
  end

  private

  def fake_dispatch_result(operation)
    case operation
    when :embed
      # 05 §3 documented artifact: { text:, model:, embedding:, usage: }
      {
        text: 'conformance', model: 'conformance', embedding: [0.1, 0.2, 0.3],
        usage: Legion::Extensions::Llm::Canonical::Usage.build(input_tokens: 0)
      }
    when :count_tokens then 42
    else
      Legion::Extensions::Llm::Canonical::Response.build(
        text: 'conformance response', model: 'conformance', stop_reason: :end_turn
      )
    end
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
      model_revision_evidence: Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent),
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

  # --- Vertex-specific instance identity (name + secondary physical_id) -------

  describe 'instance identity' do
    it 'uses the operator config name as the instance_id (the router instances.<name> key)' do
      ids = ssot_harness.instance_configs.map { |cfg| ssot_harness.instance_id(instance_config: cfg) }
      expect(ids).to eq(%w[conformance-alpha conformance-beta])
      expect(ids.uniq.size).to eq(2)
    end

    it 'reproduces the same instance_id across multiple calls (stable identity)' do
      config = ssot_harness.instance_configs.first
      id_a = ssot_harness.instance_id(instance_config: config)
      id_b = ssot_harness.instance_id(instance_config: config)
      expect(id_a).to eq(id_b)
    end

    it 'derives the secondary physical_id as project:location/fingerprint (canonical 8-char fingerprint)' do
      config = { vertex_project: 'my-project', vertex_location: 'us-central1', vertex_access_token: 'ya29.token' }
      fingerprint = Legion::Extensions::Llm::CredentialSources.credential_fingerprint('ya29.token')
      expect(fingerprint).to eq(Digest::SHA256.hexdigest('ya29.token')[0, 8])

      expect(ssot_harness.physical_id(instance_config: config)).to eq("my-project:us-central1/#{fingerprint}")
    end

    it 'returns nil physical_id for a credential-less config so the actor skips it (no fallback identity)' do
      config = { vertex_project: 'proj', vertex_location: 'us-east1' }
      expect(ssot_harness.physical_id(instance_config: config)).to be_nil
    end

    it 'returns nil physical_id for a project-less config so the actor skips it (no fallback identity)' do
      config = { vertex_location: 'us-east1', vertex_access_token: 'ya29.token' }
      expect(ssot_harness.physical_id(instance_config: config)).to be_nil
    end
  end

  # --- Two projects with same model = separate lanes --------------------------

  describe 'two Vertex projects serving the same model' do
    def bring_up_instance(config, tier: :cloud)
      publisher = Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vertex)
      instance_id = ssot_harness.instance_id(instance_config: config)
      physical_id = ssot_harness.physical_id(instance_config: config)
      key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vertex, instance_id: instance_id, physical_id: physical_id
      )
      callable = ssot_harness.build_callable(instance_config: config)
      coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
        instance_key: key, enqueue: ->(**) { true }
      )

      token = publisher.claim_instance(instance_id: instance_id, callable: callable,
                                       probe_request_handle: coordinator, physical_id: physical_id)
      probe = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: token,
                                                physical_id: physical_id)
      drafts = ssot_harness.build_offering_drafts(instance_config: config, callable: callable, tier: tier)
      publisher.activate_instance_snapshot(
        instance_id: instance_id, publisher_token: token, offerings: drafts, sequence: 0, probe_token: probe,
        physical_id: physical_id
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
    it 'classifies a real Faraday-raised SERVICE_UNAVAILABLE response as instance_unavailable' do
      error = ssot_harness.instance_unavailable_error
      expect(error.response).to be_a(Hash), 'error must come from a real raise_error round-trip'

      outcome = ssot_harness.normalize_dispatch_error(error: error)
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

    it 'classifies a real 503 as overloaded, never as instance_unavailable' do
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
        error = VertexSsotFaraday.error_for(status: status, body: '')
        outcome = callable.normalize_dispatch_error(error: error)
        expect(outcome.kind).not_to eq(:instance_unavailable),
                                    "status #{status} should not map to instance_unavailable"
      end
    end

    it 'classifies 429 as rate_limited' do
      callable = ssot_harness.build_callable(instance_config: ssot_harness.instance_configs[0])
      error = VertexSsotFaraday.error_for(status: 429, body: '')
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

    it 'implements the fleet dispatch operations' do
      expect(callable).to respond_to(:chat)
      expect(callable).to respond_to(:stream_chat)
      expect(callable).to respond_to(:embed)
      expect(callable).to respond_to(:count_tokens)
    end

    it 'responds to disconnect and normalize_dispatch_error' do
      expect(callable).to respond_to(:disconnect)
      expect(callable).to respond_to(:disconnected?)
      expect(callable).to respond_to(:normalize_dispatch_error)
    end

    it 'wraps a per-instance Vertex Provider' do
      expect(callable.provider).to be_a(Legion::Extensions::Llm::Vertex::Provider)
    end

    it 'is not disconnected on creation' do
      expect(callable.disconnected?).to be(false)
    end

    it 'closes the wrapped Provider on disconnect' do
      expect(callable.provider.connection).not_to be_nil
      callable.disconnect
      expect(callable.disconnected?).to be(true)
      expect(callable.provider.connection).to be_nil
    end

    # D15: fleet WorkerExecution and legion-llm SelectionDispatch both pass
    # model: as a RAW STRING (the offering model id). The Vertex render path
    # (Provider#model_id) accepts a plain string, so the callable delegates
    # without wrapping. These drive the real render path — not the harness
    # dispatch stubs — to keep that guarantee covered.
    describe 'raw-string model dispatch (D15)' do
      let(:fake_connection) { VertexSsotFakeConnection.new }
      # Pipeline dispatch (fleet WorkerExecution / SelectionDispatch) delivers
      # Canonical::Message objects across the callable boundary; these examples
      # drive the real render path, so the input must be the canonical shape.
      let(:message) { Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello') }

      before { callable.provider.instance_variable_set(:@connection, fake_connection) }

      it 'chats through the real render path with a raw-string model' do
        result = callable.chat([message], model: 'gemini-2.5-flash')

        expect(fake_connection.posts.first[0]).to eq(
          'projects/my-project-alpha/locations/us-central1/publishers/google/models/gemini-2.5-flash:generateContent'
        )
        expect(result).to be_a(Legion::Extensions::Llm::Canonical::Response)
        expect(result.text).to eq('done')
        expect(result.model).to eq('gemini-2.5-flash')
      end

      it 'renders a folded leading system message into the native systemInstruction field' do
        system_message = Legion::Extensions::Llm::Canonical::Message.build(
          role: :system,
          content: 'authoritative system instruction'
        )
        user_message = Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'hello')

        callable.chat([system_message, user_message], model: 'gemini-2.5-flash')

        payload = fake_connection.posts.first[1]
        expect(payload[:systemInstruction]).to eq(parts: [{ text: 'authoritative system instruction' }])
        expect(payload[:contents]).to eq([{ role: 'user', parts: [{ text: 'hello' }] }])
      end

      it 'stream_chats through the real render path with a raw-string model' do
        # The base funnel streams IFF a block is given (08 F1: stream_chat is a
        # thin delegate; stream: block_given?).
        # rubocop:disable Lint/EmptyBlock -- the block selects the stream path
        result = callable.stream_chat([message], model: 'gemini-2.5-flash') { |_chunk| }
        # rubocop:enable Lint/EmptyBlock

        expect(fake_connection.posts.first[0]).to eq(
          'projects/my-project-alpha/locations/us-central1/publishers/google/models/' \
          'gemini-2.5-flash:streamGenerateContent?alt=sse'
        )
        expect(result).to be_a(Legion::Extensions::Llm::Canonical::Response)
      end

      it 'embeds through the real render path with a raw-string model' do
        result = callable.embed(text: 'hello', model: 'gemini-embedding-001')

        expect(fake_connection.posts.first[0]).to eq(
          'projects/my-project-alpha/locations/us-central1/publishers/google/models/gemini-embedding-001:predict'
        )
        expect(result[:embedding]).to eq([0.1, 0.2])
        expect(result[:usage]).to be_a(Legion::Extensions::Llm::Canonical::Usage)
        expect(result[:usage].input_tokens).to eq(0)
      end

      it 'counts tokens through the real render path with a raw-string model' do
        result = callable.count_tokens(messages: [message], model: 'gemini-2.5-flash')

        expect(fake_connection.posts.first[0]).to eq(
          'projects/my-project-alpha/locations/us-central1/publishers/google/models/gemini-2.5-flash:countTokens'
        )
        expect(result).to eq(7)
      end
    end

    # ─── Canonical dispatch boundary regression (2026-08-19 incident) ────────
    # SSOT v3 local dispatch passed executor Hash messages straight to provider
    # callables; lenient provider-side tolerance masked the bypass. The
    # callable enforces Canonical-only at its entry (the shared helper, N x N
    # law) and the base funnel enforces centrally before rendering — plain
    # Hashes are rejected loudly at both boundaries.
    describe 'canonical dispatch boundary' do
      let(:hash_request) do
        [
          { role: 'user', content: 'What is the capital of France?' },
          { role: 'assistant', content: 'Paris.' }
        ]
      end

      it 'rejects plain Hash messages at the callable dispatch boundary' do
        expect { callable.chat(hash_request, model: 'gemini-2.5-flash') }
          .to raise_error(ArgumentError, /Canonical::Message/)
        expect { callable.stream_chat(hash_request, model: 'gemini-2.5-flash') }
          .to raise_error(ArgumentError, /Canonical::Message/)
        expect { callable.count_tokens(messages: hash_request, model: 'gemini-2.5-flash') }
          .to raise_error(ArgumentError, /Canonical::Message/)
      end

      it 'rejects plain Hash messages at the provider funnel (central enforcement, 08 F2)' do
        expect { callable.provider.chat(hash_request, model: 'gemini-2.5-flash') }
          .to raise_error(ArgumentError, /Canonical::Message/)
      end
    end

    # ─── 0.8.0 canonical boundary kit (B1/B2 against the REAL callable) ──────
    # The kit examples resolve `callable` from the host group — the shadowing
    # let below points them at the production callable wired to the offline
    # fake connection (the real render/parse paths, no network).
    describe 'canonical boundary kit (08 F2 / 05 O5)' do
      let(:fake_kit_connection) { VertexSsotFakeConnection.new }

      let(:callable) do
        target = described_class.new(
          instance_cfg: ssot_harness.instance_configs[0], logger: Logger.new(File::NULL)
        )
        target.provider.instance_variable_set(:@connection, fake_kit_connection)
        target
      end

      it_behaves_like 'B1 — central canonical enforcement (08 F2)'
      it_behaves_like 'B2 — canonical outputs (05 O5, 08 R2)'
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
    it 'permits instance_id "default" as an operator configuration name' do
      instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
        provider_family: :vertex, instance_id: 'default'
      )

      expect(instance_key.provider_family).to eq(:vertex)
      expect(instance_key.instance_id).to eq('default')
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
