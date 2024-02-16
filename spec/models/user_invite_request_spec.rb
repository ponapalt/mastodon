# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserInviteRequest do
  describe 'validations' do
    subject { described_class.new(user: Fabricate.build(:user), text: text) }

    context 'with an ordinary reason for joining' do
      let(:text) { 'I would like to join because I know people here' }

      it { is_expected.to be_valid }
    end

    context 'with only one keyword of a blocked set' do
      let(:text) { 'I am here to probe what this community is about' }

      it { is_expected.to be_valid }
    end

    context 'with all keywords of a blocked set' do
      let(:text) { 'Automated protocol deliverability probe' }

      it { is_expected.to_not be_valid }
    end

    context 'with all keywords of a blocked set in a different case, order and wording' do
      let(:text) { "Hello!\nJust a PROBE of your e-mail Deliverability, thanks" }

      it { is_expected.to_not be_valid }
    end
  end
end
