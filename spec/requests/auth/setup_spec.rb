# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Auth Setup' do
  describe 'GET /auth/setup' do
    context 'with a signed out request' do
      it 'redirects to root' do
        get '/auth/setup'

        expect(response)
          .to redirect_to(new_user_session_url)
      end
    end

    context 'with a confirmed signed in user' do
      before { sign_in Fabricate(:user, confirmed_at: 2.days.ago) }

      it 'redirects to root' do
        get '/auth/setup'

        expect(response)
          .to redirect_to(root_url)
      end
    end
  end

  describe 'PUT /auth/setup' do
    before { sign_in Fabricate(:user, confirmed_at: nil) }

    it 'gracefully handles invalid nested params' do
      put '/auth/setup?user=invalid'

      expect(response)
        .to have_http_status(400)
    end
  end
end