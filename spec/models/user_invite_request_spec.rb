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

    context 'with all keywords of another blocked set' do
      let(:text) { 'Automated account creation test' }

      it { is_expected.to_not be_valid }
    end

    context 'with an ordinary reason for joining sent from an application' do
      subject { described_class.new(user: Fabricate.build(:user, created_by_application: app), text: text) }

      let(:text) { 'I would like to join because I know people here' }

      context 'when the application name contains a blocked substring' do
        let(:app) { Fabricate.build(:application, name: 'Best SEO Tool') }

        it { is_expected.to_not be_valid }
      end

      context 'when the application name contains a blocked substring in a different case' do
        let(:app) { Fabricate.build(:application, name: 'Seoul Client') }

        it { is_expected.to be_valid }
      end
    end
  end
end
