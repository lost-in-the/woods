# frozen_string_literal: true

require 'spec_helper'
require 'woods/filename_utils'

RSpec.describe Woods::FilenameUtils do
  describe '.safe_segment' do
    it 'replaces :: with __ and other non-[A-Za-z0-9_-] chars with _' do
      expect(described_class.safe_segment('Admin::Users')).to eq('Admin__Users')
      expect(described_class.safe_segment('sign_in!')).to eq('sign_in_')
    end

    it 'is the identity transform for conventional identifiers' do
      expect(described_class.safe_segment('PostsController')).to eq('PostsController')
    end
  end

  describe '.flow_filename' do
    it 'joins the normalized controller and action with a .json suffix' do
      expect(described_class.flow_filename('Admin::UsersController', 'index'))
        .to eq('Admin__UsersController_index.json')
    end

    it 'produces the SAME name the reader and writer both derive for exotic actions' do
      # Regression: the writer previously left the action raw while the reader
      # allow-listed it, so a flow for `sign_in!` was written under one name
      # and looked up under another. Both now route through flow_filename.
      writer_name = described_class.flow_filename('SessionsController', 'sign_in!')
      # The reader derives the same value from the entry point.
      controller, action = 'SessionsController#sign_in!'.split('#', 2)
      reader_name = described_class.flow_filename(controller, action)
      expect(writer_name).to eq(reader_name)
      expect(writer_name).to eq('SessionsController_sign_in_.json')
    end
  end

  describe 'mixed-in instance API' do
    subject(:host) { Class.new { include Woods::FilenameUtils }.new }

    it 'still exposes safe_filename and collision_safe_filename' do
      expect(host.safe_filename('Admin::Users')).to eq('Admin__Users.json')
      expect(host.collision_safe_filename('Admin::Users')).to match(/\AAdmin__Users_[0-9a-f]{8}\.json\z/)
    end
  end
end
