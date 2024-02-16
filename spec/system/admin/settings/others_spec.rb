# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin::Settings::Others' do
  let(:admin_user) { Fabricate(:admin_user) }

  before { sign_in(admin_user) }

  it 'Saves changes to other settings' do
    visit admin_settings_others_path
    expect(page)
      .to have_title(I18n.t('admin.settings.others.title'))

    fill_in I18n.t('admin.settings.reject_pattern.title'),
            with: 'spam'

    click_on submit_button

    expect(page)
      .to have_text(success_message)
    expect(Setting.reject_pattern)
      .to eq('spam')
  end
end
