# frozen_string_literal: true

require_relative '../../woods/watch/puma_adapter'

Puma::Plugin.create do
  def start(launcher)
    @woods_adapter ||= Woods::Watch::PumaAdapter.new(launcher)
    @woods_adapter.install
  end
end
