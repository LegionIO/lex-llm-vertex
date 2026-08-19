# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'legion/extensions/llm/inventory/registry'

RSpec.describe Legion::Extensions::Llm::Vertex::Actor::DiscoveryRefresh do
  let(:actor) { described_class.new }
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:root_settings) { Legion::Settings.loader.settings }
  let(:provider_settings) { root_settings[:extensions][:llm][:vertex] ||= {} }
  let(:instance_cfg) do
    { project: 'prod-project', access_token: 'token-alpha', location: 'us-east1', tier: :cloud }
  end

  before do
    registry.reset!
    @previous_vertex_settings = Marshal.load(Marshal.dump(provider_settings))
    @previous_llm_settings = root_settings[:llm]
    provider_settings.clear
    root_settings[:llm] = { routing: { tier_weights: { cloud: 110 } } }
    allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
      .with(:extensions, :llm, :vertex)
      .and_return(provider_settings)
  end

  after do
    provider_settings.replace(@previous_vertex_settings)
    root_settings[:llm] = @previous_llm_settings
  end

  def healthy
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: true, reason: 'ready')
  end

  def unhealthy
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: false, reason: 'down')
  end

  def real_model
    Legion::Extensions::Llm::Vertex::Provider::STATIC_MODELS.first.fetch(:model)
  end

  def configure_alpha(weight: nil, models: nil)
    config = instance_cfg.dup
    config[:weight] = weight unless weight.nil?
    config[:models] = models unless models.nil?
    provider_settings[:instances] = { alpha: config }
  end

  def stub_health(readiness = healthy)
    allow(actor).to receive(:check_health).and_return(readiness)
  end

  def alpha_key
    fingerprint = Legion::Extensions::Llm::CredentialSources.credential_fingerprint('token-alpha')
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :vertex,
      instance_id: 'alpha',
      physical_id: "prod-project:us-east1/#{fingerprint}"
    )
  end

  def alpha_state
    actor.instance_variable_get(:@instance_states)['alpha']
  end

  def alpha_offering(model = real_model)
    registry.snapshot.offerings_for(instance_key: alpha_key).find { |offering| offering.model == model }
  end

  def build_draft(model: real_model)
    actor.send(
      :build_offering_draft,
      model_entry: Legion::Extensions::Llm::Vertex::Provider::STATIC_MODELS.find { |entry| entry[:model] == model },
      tier: :cloud,
      instance_cfg: instance_cfg,
      instance_key: alpha_key,
      now: Time.utc(2026, 8, 19).freeze
    )
  end

  def authoritative_draft_variant(draft, field)
    case field
    when :provider_native_key
      draft.with(provider_native_key: 'vertex-native-revision-v2')
    when :model
      draft.with(model: 'vertex-model-revision-v2')
    when :tier
      draft.with(tier: :frontier)
    when :operation_evidence
      evidence = draft.operation_evidence.fetch(:chat).with(metadata: { revision: 'v2' })
      draft.with(operation_evidence: draft.operation_evidence.merge(chat: evidence))
    when :capability_evidence
      capability, evidence = draft.capability_evidence.first
      draft.with(capability_evidence: draft.capability_evidence.merge(
        capability => evidence.with(metadata: { revision: 'v2' })
      ))
    when :context_evidence, :max_output_evidence, :embedding_dimensions_evidence,
         :model_revision_evidence, :tokenizer_evidence
      draft.with(field => draft.public_send(field).with(metadata: { revision: 'v2' }))
    when :quota_domains
      draft.with(quota_domains: { chat: 'vertex-chat-v2' })
    when :metadata
      draft.with(metadata: draft.metadata.merge(catalog_revision: 'v2'))
    when :publication_source
      draft.with(publication_source: :provider_control_plane)
    end
  end

  describe 'write-time weights on the ordinary discovery cadence' do
    it 'stores the exact four-axis pair and product on each constructed draft' do
      provider_settings[:weight] = 120
      provider_settings[:models] = { real_model => { weight: 125 } }
      configure_alpha(weight: 115)

      draft = build_draft

      expect(draft.weight_inputs).to eq(
        tier: 110,
        provider: 120,
        instance: 115,
        model_or_offering: 125
      )
      expect(draft.base_weight).to eq(189_750_000)
    end

    it 'publishes one replacement for a weight-only change on the next ordinary pass' do
      provider_settings[:weight] = 120
      configure_alpha
      stub_health

      actor.manual
      provider_settings[:weight] = 130
      actor.manual

      status = registry.snapshot.publication_status(instance_key: alpha_key)
      expect(status.published_sequence).to eq(1)
      expect(alpha_offering.weight_inputs[:provider]).to eq(130)
      expect(alpha_offering.base_weight).to eq(143_000_000)
      expect(actor).to have_received(:check_health).twice
    end

    it 'publishes nothing when settings change without changing the weight pair' do
      configure_alpha
      stub_health

      actor.manual
      provider_settings[:unrelated_display_option] = 'changed'
      actor.manual

      expect(registry.snapshot.publication_status(instance_key: alpha_key).published_sequence).to eq(0)
    end

    it 'stores an explicit zero component without applying the identity default' do
      provider_settings[:weight] = 0
      configure_alpha
      stub_health

      actor.manual

      expect(alpha_offering.weight_inputs[:provider]).to eq(0)
      expect(alpha_offering.base_weight).to eq(0)
    end

    it 'raises for a malformed false component instead of silently defaulting it' do
      provider_settings[:weight] = false
      configure_alpha

      expect do
        actor.send(
          :discover_offerings_for_instance,
          instance_cfg: instance_cfg,
          instance_key: alpha_key,
          now: Time.utc(2026, 8, 19).freeze
        )
      end.to raise_error(ArgumentError, /weight component must be an Integer >= 0/)
    end

    it 'keeps Data equality stable with the pinned evidence timestamp across ten unchanged passes' do
      configure_alpha
      stub_health

      actor.manual
      10.times { actor.manual }

      expect(registry.snapshot.publication_status(instance_key: alpha_key).published_sequence).to eq(0)
      expect(alpha_state[:sequence]).to eq(0)
    end

    it 'constructs the frozen static catalog in deterministic declaration order without cadence churn' do
      configure_alpha
      stub_health
      publisher = actor.send(:publisher)
      allow(publisher).to receive(:replace_instance_snapshot).and_call_original

      actor.manual
      expected_order = Legion::Extensions::Llm::Vertex::Provider::STATIC_MODELS.filter_map do |entry|
        entry[:model] unless entry[:model].to_s.empty?
      end
      expect(alpha_state.fetch(:offerings).map(&:provider_native_key)).to eq(expected_order)

      actor.manual

      expect(publisher).not_to have_received(:replace_instance_snapshot)
      expect(alpha_state[:sequence]).to eq(0)
    end

    it 'covers every OfferingDraft member through field or validated weight-pair cadence cases' do
      covered_fields = %i[
        provider_native_key model tier operation_evidence capability_evidence context_evidence
        max_output_evidence embedding_dimensions_evidence model_revision_evidence tokenizer_evidence
        quota_domains metadata publication_source weight_inputs base_weight
      ]
      expect(Legion::Extensions::Llm::Inventory::OfferingDraft.members).to match_array(covered_fields)
    end

    %i[
      provider_native_key model tier operation_evidence capability_evidence context_evidence
      max_output_evidence embedding_dimensions_evidence model_revision_evidence tokenizer_evidence
      quota_domains metadata publication_source
    ].each do |field|
      it "publishes exactly once when the authoritative #{field} contract changes" do
        configure_alpha
        stub_health
        actor.manual
        previous = alpha_state.fetch(:offerings)
        changed = previous.dup
        changed[0] = authoritative_draft_variant(previous.first, field)
        allow(actor).to receive(:discover_offerings_for_instance).and_return(changed)
        publisher = actor.send(:publisher)
        allow(publisher).to receive(:replace_instance_snapshot).and_call_original

        actor.manual

        expect(previous).not_to eq(changed)
        expect(publisher).to have_received(:replace_instance_snapshot).once
        expect(registry.snapshot.publication_status(instance_key: alpha_key).published_sequence).to eq(1)
        expect(alpha_state[:sequence]).to eq(1)
      end
    end

    it 'treats duplicate multiplicity as unequal and significant on the ordinary cadence' do
      configure_alpha
      stub_health
      actor.manual
      previous = alpha_state.fetch(:offerings)
      duplicated = previous + [previous.first]
      allow(actor).to receive(:discover_offerings_for_instance).and_return(duplicated)
      publisher = actor.send(:publisher)
      replacements = []
      allow(publisher).to receive(:replace_instance_snapshot) { |**kwargs| replacements << kwargs }

      actor.manual

      expect(previous).not_to eq(duplicated)
      expect(replacements.length).to eq(1)
      expect(replacements.first.fetch(:offerings).length).to eq(previous.length + 1)
      expect(alpha_state[:sequence]).to eq(1)
    end

    it 'logs each dormant model once, clears it on appearance, and logs its re-disappearance' do
      output = StringIO.new
      allow(actor).to receive(:log).and_return(Logger.new(output))
      provider_settings[:models] = { real_model => { weight: 125 } }
      provider_settings[:instances] = {}
      stub_health

      actor.manual
      actor.manual
      configure_alpha
      provider_settings[:models] = { real_model => { weight: 125 } }
      actor.manual
      provider_settings[:instances] = {}
      actor.manual

      dormant_lines = output.string.lines.grep(/\[llm\]\[vertex\] action=dormant_weight/)
      expect(dormant_lines.size).to eq(2)
      expect(dormant_lines).to all(include("weight_key=[:vertex, :model, #{real_model.inspect}]"))
    end

    it 'never couples its ordinary pass or shutdown to Settings lifecycle methods' do
      configure_alpha
      stub_health
      allow(Legion::Settings).to receive(:on_reload)
      allow(Legion::Settings).to receive(:reload!)
      allow(Legion::Settings).to receive(:reset!)

      actor.manual
      actor.manual
      actor.shutdown

      expect(Legion::Settings).not_to have_received(:on_reload)
      expect(Legion::Settings).not_to have_received(:reload!)
      expect(Legion::Settings).not_to have_received(:reset!)
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
    end

    it 'serializes concurrent passes to at most one replacement per weight value' do
      configure_alpha
      stub_health
      actor.manual

      sequences = (121..130).map do |weight|
        provider_settings[:weight] = weight
        threads = Array.new(2) do
          Thread.new do
            actor.send(:replace_offerings_if_changed, instance_id: 'alpha', state: alpha_state)
          end
        end
        threads.each(&:join)
        registry.snapshot.publication_status(instance_key: alpha_key).published_sequence
      end

      expect(sequences).to eq((1..10).to_a)
      expect(alpha_state[:sequence]).to eq(10)
      state_offering = alpha_state[:offerings].first
      expect(state_offering.base_weight).to eq(alpha_offering(state_offering.model).base_weight)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(130)
    end

    it 'leaves the cache unchanged after replacement failure and retries on the next pass' do
      provider_settings[:weight] = 120
      configure_alpha
      stub_health
      actor.manual
      original = actor.send(:publisher).method(:replace_instance_snapshot)
      attempts = 0
      allow(actor.send(:publisher)).to receive(:replace_instance_snapshot) do |**kwargs|
        attempts += 1
        raise 'publisher unavailable' if attempts == 1

        original.call(**kwargs)
      end
      provider_settings[:weight] = 130

      actor.manual

      expect(alpha_state[:sequence]).to eq(0)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(120)

      actor.manual

      expect(alpha_state[:sequence]).to eq(1)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(130)
      expect(alpha_offering.weight_inputs[:provider]).to eq(130)
    end
  end

  describe 'two-phase initial publication' do
    it 'does not claim malformed startup weights and recovers once on the next valid tick' do
      provider_settings[:weight] = false
      configure_alpha
      stub_health
      publisher = actor.send(:publisher)
      callable_class = Legion::Extensions::Llm::Vertex::Actor::VertexCallable
      allow(publisher).to receive(:claim_instance).and_call_original
      allow(callable_class).to receive(:new).and_call_original

      actor.manual

      expect(registry.snapshot.publication_status(instance_key: alpha_key)).to be_nil
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
      expect(actor.instance_variable_get(:@instance_states)).to be_empty
      expect(publisher).not_to have_received(:claim_instance)
      expect(callable_class).not_to have_received(:new)

      provider_settings[:weight] = 120
      actor.manual

      expect(publisher).to have_received(:claim_instance).once
      expect(callable_class).to have_received(:new).once
      expect(registry.snapshot.publication_status(instance_key: alpha_key).state).to eq(:complete)
      expect(registry.snapshot.instance(instance_key: alpha_key).availability.state).to eq(:available)
      expect(actor.instance_variable_get(:@instance_states).keys).to eq(['alpha'])
    end

    it 'rebuilds from current settings after a weight changes during readiness' do
      provider_settings[:weight] = 120
      configure_alpha
      readiness_started = Queue.new
      resume_readiness = Queue.new
      allow(actor).to receive(:check_health) do
        readiness_started << true
        resume_readiness.pop
        healthy
      end

      thread = Thread.new { actor.manual }
      readiness_started.pop
      provider_settings[:weight] = 130
      resume_readiness << true
      thread.join

      expect(alpha_offering.weight_inputs[:provider]).to eq(130)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(130)
      expect(alpha_state[:published]).to be(true)
    end

    it 'updates an unpublished cache without replacing or satisfying dormant matching' do
      output = StringIO.new
      allow(actor).to receive(:log).and_return(Logger.new(output))
      provider_settings[:weight] = 120
      provider_settings[:models] = { real_model => { weight: 125 } }
      configure_alpha
      provider_settings[:models] = { real_model => { weight: 125 } }
      stub_health(unhealthy)

      actor.manual
      provider_settings[:weight] = 130
      actor.manual

      expect(alpha_state).to include(sequence: 0, published: false)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(130)
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
      dormant_pattern = /weight_key=\[:vertex, :model, #{Regexp.escape(real_model.inspect)}\]/
      expect(output.string.lines.grep(dormant_pattern).size).to eq(1)
    end

    it 'does not resurrect a tracked state removed while readiness is in flight' do
      configure_alpha
      readiness_started = Queue.new
      resume_readiness = Queue.new
      allow(actor).to receive(:check_health) do
        readiness_started << true
        resume_readiness.pop
        healthy
      end

      thread = Thread.new { actor.manual }
      readiness_started.pop
      actor.shutdown
      resume_readiness << true
      thread.join

      expect(actor.instance_variable_get(:@instance_states)).to be_empty
      expect(registry.snapshot.instance(instance_key: alpha_key)).to be_nil
      expect(provider_settings.dig(:instances, :alpha, :health)).to be_nil
      expect(provider_settings.dig(:instances, :alpha, :capabilities)).to be_nil
    end

    it 'preserves initializing state after activation failure and retries successfully' do
      provider_settings[:weight] = 120
      configure_alpha
      allow(actor).to receive(:check_health) do
        provider_settings[:weight] = 130
        healthy
      end
      original = actor.send(:publisher).method(:activate_instance_snapshot)
      attempts = 0
      allow(actor.send(:publisher)).to receive(:activate_instance_snapshot) do |**kwargs|
        attempts += 1
        raise 'activation unavailable' if attempts == 1

        original.call(**kwargs)
      end

      actor.manual

      expect(alpha_state).to include(sequence: 0, published: false)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(120)

      actor.manual

      expect(alpha_state).to include(sequence: 0, published: true)
      expect(alpha_state[:offerings].first.weight_inputs[:provider]).to eq(130)
      expect(alpha_offering.weight_inputs[:provider]).to eq(130)
    end
  end
end
