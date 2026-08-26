# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/vertex/runners/discovery'

# Lifecycle against the post-collapse boundary: the offline driving surface is
# the provider's discovery runner module (Runners::Discovery, which mixes in
# the shared Discovery::Pipeline). The generic reconcile/claim/activate/probe
# pipeline is exercised here only through its provider-specific overrides —
# static catalog, project:location physical id, and the settings write-back.
RSpec.describe Legion::Extensions::Llm::Vertex::Runners::Discovery do
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:instance_cfg) { { project: 'prod-proj', access_token: 'tok-prod', location: 'us-east1' } }

  before do
    registry.reset!
    described_class.reset_state!
    @previous_vertex_settings = Marshal.load(
      Marshal.dump(Legion::Settings.loader.settings.dig(:extensions, :llm, :vertex))
    )
  end

  after do
    root = Legion::Settings.loader.settings
    root[:extensions] ||= {}
    root[:extensions][:llm] ||= {}
    root[:extensions][:llm][:vertex] = @previous_vertex_settings
  end

  def configure_vertex(config)
    allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
      .with(:extensions, :llm, :vertex)
      .and_return(config)
    # The shared pipeline's health/capabilities write-back reads the REAL
    # settings tree through the Lex helper (settings.dig(:instances, name)) —
    # seed the genuine tree, not just the CredentialSources stub.
    root = Legion::Settings.loader.settings
    root[:extensions] ||= {}
    root[:extensions][:llm] ||= {}
    root[:extensions][:llm][:vertex] = config
  end

  # Secondary physical identity (dedup/diagnostics) — NOT the instance
  # identity. The identity is the operator's config name.
  def physical_id_for(instance_cfg)
    Legion::Extensions::Llm::CredentialSources.credential_fingerprint(
      instance_cfg[:access_token] || instance_cfg[:credentials]
    ).then { |fp| "#{instance_cfg[:project]}:#{instance_cfg[:location]}/#{fp}" }
  end

  def key_for(name, instance_cfg)
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
      provider_family: :vertex, instance_id: name.to_s, physical_id: physical_id_for(instance_cfg)
    )
  end

  def ready_readiness
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: true, reason: 'Vertex models-list returned 200', metadata: { status: 200 }
    )
  end

  def failed_readiness
    Legion::Extensions::Llm::Inventory::ReadinessResult.new(
      ready: false, reason: 'Vertex models-list returned 403', metadata: { status: 403 }
    )
  end

  # The readiness probe is a real HTTP models-list call in production; the
  # offline spec drives it through the runner's own check_health seam.
  def stub_health(readiness)
    allow(described_class).to receive(:check_health).and_return(readiness)
  end

  # --- Discovery / activation --------------------------------------------------

  describe '#refresh (initial discovery)' do
    it 'claims and activates a configured instance and writes display health' do
      configure_vertex(instances: { prod: instance_cfg })
      stub_health(ready_readiness)
      described_class.refresh

      key = key_for(:prod, instance_cfg)
      record = registry.snapshot.instance(instance_key: key)
      expect(record).not_to be_nil
      # Identity is the operator's config name; the derived
      # project:location/fingerprint rides along as the secondary physical_id.
      expect(record.instance_key.instance_id).to eq('prod')
      expect(record.instance_key.physical_id).to eq(physical_id_for(instance_cfg))
      expect(record.availability.state).to eq(:available)
      expect(record.availability.source).to eq(:startup_readiness)

      health = described_class.settings.dig(:instances, :prod, :health)
      expect(health).to include(
        state: :available,
        reason: 'startup readiness succeeded',
        last_probe_outcome: :success,
        source: :startup_readiness
      )
      # The pipeline stores Time.now (local); health_hash iso8601s it, so the
      # offset is the host's, not necessarily Z.
      iso8601 = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/
      expect(health[:observed_at]).to match(iso8601)
      expect(described_class.settings.dig(:instances, :prod, :capabilities))
        .to include(:completion, :streaming, :embedding)
    end

    it 'publishes per-model capability evidence from the static catalog (chat vs embedding models)' do
      configure_vertex(instances: { prod: instance_cfg })
      stub_health(ready_readiness)
      described_class.refresh

      lanes = registry.snapshot.lanes_for(instance_key: key_for(:prod, instance_cfg))
      chat_lane = lanes.find { |lane| lane.model == 'gemini-2.5-flash' }
      embed_lane = lanes.find { |lane| lane.model == 'gemini-embedding-001' }
      expect(chat_lane.capability_evidence[:completion].supported?).to be(true)
      expect(chat_lane.capability_evidence[:streaming].supported?).to be(true)
      expect(embed_lane.capability_evidence).to have_key(:embedding)
      expect(embed_lane.capability_evidence[:embedding].supported?).to be(true)
    end

    it 'stays initializing with degraded display health after an initial readiness failure' do
      configure_vertex(instances: { prod: instance_cfg })
      stub_health(failed_readiness)
      described_class.refresh

      key = key_for(:prod, instance_cfg)
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)

      health = described_class.settings.dig(:instances, :prod, :health)
      expect(health).to include(
        state: :initializing,
        reason: 'Vertex models-list returned 403',
        last_probe_outcome: :failure,
        source: :startup_readiness
      )
    end

    it 'skips named instances without a resolvable project/credential (no fallback identity claimed)' do
      configure_vertex(instances: { broken: { location: 'us-east1' } })
      stub_health(ready_readiness)
      described_class.refresh

      expect(registry.snapshot.each_publication_status.to_a).to be_empty
      expect(described_class.settings.dig(:instances, :broken, :health)).to be_nil
      expect(described_class.settings.dig(:instances, :broken, :capabilities)).to be_nil
    end

    it 'claims a top-level (un-named) configured instance' do
      configure_vertex({ project: 'top-proj', access_token: 'tok-top', location: 'us-central1' })
      stub_health(ready_readiness)
      described_class.refresh

      key = key_for(:settings, { project: 'top-proj', location: 'us-central1', access_token: 'tok-top' })
      record = registry.snapshot.instance(instance_key: key)
      expect(record.availability.state).to eq(:available)
      # The write-back targets instances.<name> in the operator config; the
      # un-named instance has no such slot, so nothing is written back.
      expect(described_class.settings.dig(:instances, :settings)).to be_nil
    end
  end

  # --- Initial-failure recovery (D4) -------------------------------------------

  describe 'initial-failure recovery' do
    it 're-activates an :initializing instance when a later tick probe passes' do
      configure_vertex(instances: { prod: instance_cfg })
      allow(described_class).to receive(:check_health).and_return(failed_readiness, ready_readiness)
      described_class.refresh

      key = key_for(:prod, instance_cfg)
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)

      described_class.refresh # tick: cadence probe passes -> re-activation

      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(described_class.settings.dig(:instances, :prod, :health)).to include(
        state: :available, last_probe_outcome: :success
      )
    end

    it 'keeps an :initializing instance initializing while probes keep failing' do
      configure_vertex(instances: { prod: instance_cfg })
      stub_health(failed_readiness)
      described_class.refresh
      described_class.refresh

      key = key_for(:prod, instance_cfg)
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end
  end

  # --- Tick reconcile ------------------------------------------------------------

  describe '#refresh (tick reconcile)' do
    it 'picks up a late-configured instance and retires a removed one' do
      staging_cfg = { project: 'stg-proj', access_token: 'tok-stg', location: 'europe-west1' }
      configure_vertex(instances: { prod: instance_cfg })
      stub_health(ready_readiness)
      described_class.refresh

      prod_key = key_for(:prod, instance_cfg)
      expect(registry.snapshot.instance(instance_key: prod_key)).not_to be_nil

      configure_vertex(instances: { prod: instance_cfg, staging: staging_cfg })
      described_class.refresh

      staging_key = key_for(:staging, staging_cfg)
      expect(registry.snapshot.instance(instance_key: staging_key).availability.state).to eq(:available)
      expect(described_class.settings.dig(:instances, :staging, :health)).to include(state: :available)

      configure_vertex(instances: {})
      described_class.refresh

      expect(registry.snapshot.instance(instance_key: prod_key)).to be_nil
      expect(registry.snapshot.instance(instance_key: staging_key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: prod_key)).to be_nil
      expect(described_class.settings.dig(:instances, :prod)).to be_nil
      expect(described_class.settings.dig(:instances, :staging)).to be_nil
    end

    it 'does not re-publish an unchanged instance on the next tick (no offering churn)' do
      configure_vertex(instances: { prod: instance_cfg })
      stub_health(ready_readiness)
      described_class.refresh

      key = key_for(:prod, instance_cfg)
      sequence = registry.snapshot.instance(instance_key: key).published_sequence

      described_class.refresh

      expect(registry.snapshot.instance(instance_key: key).published_sequence).to eq(sequence)
    end
  end

  # --- Cadence interval (D9) -----------------------------------------------------

  describe '#time' do
    let(:actor) { Legion::Extensions::Llm::Vertex::Actor::Discovery.new }

    before { configure_vertex({}) }

    it 'reads the registered discovery interval' do
      actor.settings[:discovery] = { interval_seconds: 123 }
      expect(actor.time).to eq(123)
    end

    it 'never returns nil or a non-positive interval for a missing or broken config' do
      expect(actor.time).to be_a(Numeric)
      expect(actor.time).to be_positive

      actor.settings[:discovery] = { interval_seconds: nil }
      expect(actor.time).to be_a(Numeric)

      actor.settings[:discovery] = { interval_seconds: -5 }
      expect(actor.time).to be_positive
    end
  end

  # --- Shutdown --------------------------------------------------------------------

  describe 'remove_all_instances' do
    it 'removes all claimed instances and clears display health' do
      configure_vertex(instances: { prod: instance_cfg })
      stub_health(ready_readiness)
      described_class.refresh

      described_class.remove_all_instances

      expect(registry.snapshot.each_publication_status.to_a).to be_empty
      expect(described_class.states.keys).to be_empty
      expect(described_class.settings.dig(:instances, :prod, :health)).to be_nil
      expect(described_class.settings.dig(:instances, :prod, :capabilities)).to be_nil
    end
  end
end
