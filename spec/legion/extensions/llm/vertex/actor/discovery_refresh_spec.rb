# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/vertex/actors/discovery_refresh'

RSpec.describe Legion::Extensions::Llm::Vertex::Actor::DiscoveryRefresh do
  let(:registry) { Legion::Extensions::Llm::Inventory::Registry }
  let(:actor) { described_class.new }
  let(:instance_cfg) { { project: 'prod-proj', access_token: 'tok-prod', location: 'us-east1' } }

  before { registry.reset! }

  def configure_vertex(config)
    allow(Legion::Extensions::Llm::CredentialSources).to receive(:setting)
      .with(:extensions, :llm, :vertex)
      .and_return(config)
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
  # offline spec drives it through the actor's own check_health seam.
  def stub_health(readiness)
    allow(actor).to receive(:check_health).and_return(readiness)
  end

  # --- Discovery / activation --------------------------------------------------

  describe '#manual (initial discovery)' do
    it 'claims and activates a configured instance and writes display health' do
      configure_vertex(instances: { prod: instance_cfg })
      stub_health(ready_readiness)
      actor.manual

      key = key_for(:prod, instance_cfg)
      record = registry.snapshot.instance(instance_key: key)
      expect(record).not_to be_nil
      # Identity is the operator's config name; the derived
      # project:location/fingerprint rides along as the secondary physical_id.
      expect(record.instance_key.instance_id).to eq('prod')
      expect(record.instance_key.physical_id).to eq(physical_id_for(instance_cfg))
      expect(record.availability.state).to eq(:available)
      expect(record.availability.source).to eq(:startup_readiness)

      health = actor.settings[:instances][:prod][:health]
      expect(health).to include(
        circuit_state: :closed, denied: false, available: true, adjustment: 0,
        source: :ssot_discovery_actor, reason: 'startup readiness succeeded', last_probe_outcome: :success
      )
      expect(health[:observed_at]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
      expect(actor.settings[:instances][:prod][:capabilities]).to include(:completion, :streaming, :embedding)
    end

    it 'stays initializing with degraded display health after an initial readiness failure' do
      configure_vertex(instances: { prod: instance_cfg })
      stub_health(failed_readiness)
      actor.manual

      key = key_for(:prod, instance_cfg)
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)

      health = actor.settings[:instances][:prod][:health]
      expect(health).to include(
        circuit_state: :half_open, denied: false, available: false, adjustment: -50,
        last_probe_outcome: :failure, reason: 'Vertex models-list returned 403'
      )
    end

    it 'skips named instances without a resolvable project/credential (no fallback identity claimed)' do
      configure_vertex(instances: { broken: { location: 'us-east1' } })
      stub_health(ready_readiness)
      actor.manual

      expect(registry.snapshot.each_publication_status.to_a).to be_empty
      expect(actor.settings[:instances][:broken]).to be_nil
    end

    it 'claims a top-level (un-named) configured instance' do
      configure_vertex({ project: 'top-proj', access_token: 'tok-top', location: 'us-central1' })
      stub_health(ready_readiness)
      actor.manual

      key = key_for(:settings, { project: 'top-proj', location: 'us-central1', access_token: 'tok-top' })
      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(actor.settings[:instances][:settings][:health]).to include(available: true, circuit_state: :closed)
    end
  end

  # --- Initial-failure recovery (D4) -------------------------------------------

  describe 'initial-failure recovery' do
    it 're-activates an :initializing instance when a later tick probe passes' do
      configure_vertex(instances: { prod: instance_cfg })
      allow(actor).to receive(:check_health).and_return(failed_readiness, ready_readiness)
      actor.manual

      key = key_for(:prod, instance_cfg)
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)

      actor.manual # tick: cadence probe passes -> re-activation

      expect(registry.snapshot.instance(instance_key: key).availability.state).to eq(:available)
      expect(actor.settings[:instances][:prod][:health]).to include(
        circuit_state: :closed, available: true, adjustment: 0
      )
    end

    it 'keeps an :initializing instance initializing while probes keep failing' do
      configure_vertex(instances: { prod: instance_cfg })
      stub_health(failed_readiness)
      actor.manual
      actor.manual

      key = key_for(:prod, instance_cfg)
      expect(registry.snapshot.instance(instance_key: key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: key).state).to eq(:initializing)
    end
  end

  # --- Tick reconcile ------------------------------------------------------------

  describe '#manual (tick reconcile)' do
    it 'picks up a late-configured instance and retires a removed one' do
      staging_cfg = { project: 'stg-proj', access_token: 'tok-stg', location: 'europe-west1' }
      configure_vertex(instances: { prod: instance_cfg })
      stub_health(ready_readiness)
      actor.manual

      prod_key = key_for(:prod, instance_cfg)
      expect(registry.snapshot.instance(instance_key: prod_key)).not_to be_nil

      configure_vertex(instances: { prod: instance_cfg, staging: staging_cfg })
      actor.manual

      staging_key = key_for(:staging, staging_cfg)
      expect(registry.snapshot.instance(instance_key: staging_key).availability.state).to eq(:available)
      expect(actor.settings[:instances][:staging][:health]).to include(available: true)

      configure_vertex(instances: {})
      actor.manual

      expect(registry.snapshot.instance(instance_key: prod_key)).to be_nil
      expect(registry.snapshot.instance(instance_key: staging_key)).to be_nil
      expect(registry.snapshot.publication_status(instance_key: prod_key)).to be_nil
      expect(actor.settings[:instances][:prod][:health]).to be_nil
      expect(actor.settings[:instances][:prod][:capabilities]).to be_nil
      expect(actor.settings[:instances][:staging][:health]).to be_nil
    end

    it 'does not re-publish an unchanged instance on the next tick (no offering churn)' do
      configure_vertex(instances: { prod: instance_cfg })
      stub_health(ready_readiness)
      actor.manual

      key = key_for(:prod, instance_cfg)
      sequence = registry.snapshot.instance(instance_key: key).published_sequence

      actor.manual

      expect(registry.snapshot.instance(instance_key: key).published_sequence).to eq(sequence)
    end
  end

  # --- Publisher wiring (D2) ------------------------------------------------------

  describe 'publisher wiring' do
    it 'injects the LegacyCoordinatorAdapter into the Publisher' do
      publisher = actor.send(:publisher)
      expect(publisher.instance_variable_get(:@compatibility_adapter))
        .to be_a(Legion::Extensions::Llm::Inventory::ScopedRefresher::LegacyCoordinatorAdapter)
    end
  end

  # --- Cadence interval (D9) -----------------------------------------------------

  describe '#time' do
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

  describe '#shutdown' do
    it 'removes all claimed instances and clears display health' do
      configure_vertex(instances: { prod: instance_cfg })
      stub_health(ready_readiness)
      actor.manual

      actor.shutdown

      expect(registry.snapshot.each_publication_status.to_a).to be_empty
      expect(actor.settings[:instances][:prod][:health]).to be_nil
      expect(actor.settings[:instances][:prod][:capabilities]).to be_nil
    end
  end
end
