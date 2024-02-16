# frozen_string_literal: true

# == Schema Information
#
# Table name: user_invite_requests
#
#  id         :bigint(8)        not null, primary key
#  text       :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint(8)        not null
#

class UserInviteRequest < ApplicationRecord
  TEXT_SIZE_LIMIT = 420

  # Keyword sets only ever seen together in reasons from automated sign-up
  # probes. A sign-up whose reason contains every keyword of any one set,
  # in any order, is rejected during validation, so no account, invite
  # request or notification e-mail is ever created for it
  BLOCKED_KEYWORD_SETS = [
    %w(deliverability probe),
  ].freeze

  belongs_to :user, inverse_of: :invite_request
  validates :text, presence: true, length: { maximum: TEXT_SIZE_LIMIT }
  validate :validate_text_not_blocked, on: :create

  private

  def validate_text_not_blocked
    normalized_text = text.to_s.downcase

    errors.add(:text, :invalid) if BLOCKED_KEYWORD_SETS.any? { |keywords| keywords.all? { |keyword| normalized_text.include?(keyword) } }
  end
end
