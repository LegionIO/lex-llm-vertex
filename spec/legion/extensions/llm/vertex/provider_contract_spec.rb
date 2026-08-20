# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/vertex/provider'

# 0.8.0 provider funnel contract (08 F1-F3): the base complete funnel is the
# single completion path — Vertex must not re-implement it — and the
# message-consuming operations take canonical keyword entries.
RSpec.describe Legion::Extensions::Llm::Vertex::Provider do
  it 'does not override the base completion funnel (chat/stream_chat/complete)' do
    %i[chat stream_chat complete].each do |method_name|
      owner = described_class.instance_method(method_name).owner
      expect(owner).to eq(Legion::Extensions::Llm::Provider),
                       "#{method_name} must stay the base funnel (got #{owner})"
    end
  end

  it 'takes canonical keyword entries for count_tokens and embed' do
    count_params = described_class.instance_method(:count_tokens).parameters
    expect(count_params).to include(%i[keyreq messages])
    expect(count_params).not_to include(%i[req messages])

    embed_params = described_class.instance_method(:embed).parameters
    expect(embed_params).to include(%i[keyreq text])
    expect(embed_params).not_to include(%i[req text])
  end

  it 'exposes no temperature kwarg outside Canonical::Params (05 O4)' do
    %i[chat stream_chat complete count_tokens embed].each do |method_name|
      params = described_class.instance_method(method_name).parameters
      expect(params.filter_map { |type, name| %i[keyreq keyrest].include?(type) ? name : nil })
        .not_to include(:temperature), "#{method_name} still takes a temperature: kwarg"
    end
  end
end
