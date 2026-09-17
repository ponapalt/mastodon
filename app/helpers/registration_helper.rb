# frozen_string_literal: true

module RegistrationHelper
  extend ActiveSupport::Concern

  # Server-wide minimum delay between sign-ups. Every sign-up resets it,
  # including one that is still only a request awaiting approval and one made
  # with an invite, so that a burst of automated sign-ups cannot get through.
  # Only accounts that went through the public sign-up paths count, as those
  # are the only ones that record a sign_up_ip; accounts created by an admin
  # through the CLI never hold up sign-ups.
  DEFAULT_REGISTRATION_INTERVAL = 2.hours

  def allowed_registration?(remote_ip, invite)
    !Rails.configuration.x.single_user_mode && !omniauth_only? && (registrations_open? || invite&.valid_for_use?) && !ip_blocked?(remote_ip)
  end

  def registrations_open?
    Setting.registrations_mode != 'none'
  end

  def omniauth_only?
    ENV['OMNIAUTH_ONLY'] == 'true'
  end

  def ip_blocked?(remote_ip)
    IpBlock.severity_sign_up_block.containing(remote_ip.to_s).exists?
  end

  def registration_interval
    seconds = ENV.fetch('REGISTRATION_INTERVAL', nil).to_i
    seconds.positive? ? seconds.seconds : DEFAULT_REGISTRATION_INTERVAL
  end

  def registration_interval_elapsed?
    last_sign_up_at = User.where.not(sign_up_ip: nil).order(id: :desc).pick(:created_at)

    last_sign_up_at.nil? || last_sign_up_at <= registration_interval.ago
  end

  def terms_agreement_label
    if TermsOfService.live.exists?
      t('auth.user_agreement_html', privacy_policy_path: privacy_policy_path, terms_of_service_path: terms_of_service_path)
    else
      t('auth.user_privacy_agreement_html', privacy_policy_path: privacy_policy_path)
    end
  end
end
