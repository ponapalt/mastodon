# frozen_string_literal: true

class ActivityPub::Activity::Create < ActivityPub::Activity
  include FormattingHelper

  def perform
    @account.schedule_refresh_if_stale!

    dereference_object!

    create_status
  end

  private

  def reject_pattern?
    if @object['content'].nil?
      return false
    else
      content_text = convert_text(@object['content'])
      is_reject = Setting.reject_pattern.present? && content_text =~ /#{Setting.reject_pattern}/
      if is_reject
        Rails.logger.error "rejected-string: " + (@object['atomUri'].present? ? @object['atomUri'] : '') + " | [" + content_text + "]"
      end
      return is_reject
    end
  end

  def create_status
    return reject_payload! if unsupported_object_type? || non_matching_uri_hosts?(@account.uri, object_uri) || tombstone_exists? || !related_to_local_activity? || reject_pattern?

    with_redis_lock("create:#{object_uri}") do
      return if delete_arrived_first?(object_uri) || poll_vote?

      @status = find_existing_status

      if @status.nil?
        process_status
      elsif @options[:delivered_to_account_id].present?
        postprocess_audience_and_deliver
      end
    end

    @status
  end

  def audience_to
    as_array(@object['to'] || @json['to']).map { |x| value_or_id(x) }
  end

  def audience_cc
    as_array(@object['cc'] || @json['cc']).map { |x| value_or_id(x) }
  end

  def process_status
    @tags                 = []
    @mentions             = []
    @unresolved_mentions  = []
    @silenced_account_ids = []
    @params               = {}
    @quote                = nil
    @quote_uri            = nil

    process_status_params
    process_tags
    process_quote
    process_audience

    ApplicationRecord.transaction do
      @status = Status.create!(@params)
      attach_tags(@status)
      attach_mentions(@status)
      attach_counts(@status)
      attach_quote(@status)

      # Delete status on zero follower user and nearly created account with include some replies
      if like_a_spam?
        @status = nil
        Rails.logger.error "rejected-algorithm: " + (@object['atomUri'].present? ? @object['atomUri'] : '') + ' | [' + convert_text(@object['content']) + ']'
        raise ActiveRecord::Rollback
      end
    end

    return if @status.nil?

    resolve_thread(@status)
    resolve_unresolved_mentions(@status)
    fetch_replies(@status)
    distribute
    forward_for_reply
  end

  def distribute
    # Spread out crawling randomly to avoid DDoSing the link
    LinkCrawlWorker.perform_in(rand(1..59).seconds, @status.id)

    # Distribute into home and list feeds and notify mentioned accounts
    ::DistributionWorker.perform_async(@status.id, { 'silenced_account_ids' => @silenced_account_ids }) if @options[:override_timestamps] || @status.within_realtime_window?
  end

  def find_existing_status
    status   = status_from_uri(object_uri)
    status ||= Status.find_by(uri: @object['atomUri']) if @object['atomUri'].present?
    status if status&.account_id == @account.id
  end

  def process_status_params
    @status_parser = ActivityPub::Parser::StatusParser.new(
      @json,
      followers_collection: @account.followers_url,
      actor_uri: ActivityPub::TagManager.instance.uri_for(@account),
      object: @object
    )

    attachment_ids = process_attachments.take(Status::MEDIA_ATTACHMENTS_LIMIT).map(&:id)

    @params = {
      uri: @status_parser.uri,
      url: @status_parser.url || @status_parser.uri,
      account: @account,
      text: converted_object_type? ? converted_text : (@status_parser.text || ''),
      language: @status_parser.language,
      spoiler_text: converted_object_type? ? '' : (@status_parser.spoiler_text || ''),
      created_at: @status_parser.created_at,
      edited_at: @status_parser.edited_at && @status_parser.edited_at != @status_parser.created_at ? @status_parser.edited_at : nil,
      override_timestamps: @options[:override_timestamps],
      reply: @status_parser.reply,
      sensitive: @account.sensitized? || @status_parser.sensitive || false,
      visibility: @status_parser.visibility,
      thread: replied_to_status,
      conversation: conversation_from_uri(@object['conversation']),
      media_attachment_ids: attachment_ids,
      ordered_media_attachment_ids: attachment_ids,
      poll: process_poll,
      quote_approval_policy: @status_parser.quote_policy,
    }
  end

  def process_audience
    # Unlike with tags, there is no point in resolving accounts we don't already
    # know here, because silent mentions would only be used for local access control anyway
    accounts_in_audience = (audience_to + audience_cc).uniq.filter_map do |audience|
      account_from_uri(audience) unless ActivityPub::TagManager.instance.public_collection?(audience)
    end

    # If the payload was delivered to a specific inbox, the inbox owner must have
    # access to it, unless they already have access to it anyway
    if @options[:delivered_to_account_id]
      accounts_in_audience << delivered_to_account
      accounts_in_audience.uniq!
    end

    accounts_in_audience.each do |account|
      # This runs after tags are processed, and those translate into non-silent
      # mentions, which take precedence
      next if @mentions.any? { |mention| mention.account_id == account.id }

      @mentions << Mention.new(account: account, silent: true)

      # If there is at least one silent mention, then the status can be considered
      # as a limited-audience status, and not strictly a direct message, but only
      # if we considered a direct message in the first place
      @params[:visibility] = :limited if @params[:visibility] == :direct
    end

    # Accounts that are tagged but are not in the audience are not
    # supposed to be notified explicitly
    @silenced_account_ids = @mentions.map(&:account_id) - accounts_in_audience.map(&:id)
  end

  def postprocess_audience_and_deliver
    return if @status.mentions.find_by(account_id: @options[:delivered_to_account_id])

    @status.mentions.create(account: delivered_to_account, silent: true)
    @status.update(visibility: :limited) if @status.direct_visibility?

    return unless delivered_to_account.following?(@account)

    FeedInsertWorker.perform_async(@status.id, delivered_to_account.id, 'home')
  end

  def delivered_to_account
    @delivered_to_account ||= Account.find(@options[:delivered_to_account_id])
  end

  def attach_tags(status)
    @tags.each do |tag|
      status.tags << tag
      tag.update(last_status_at: status.created_at) if tag.last_status_at.nil? || (tag.last_status_at < status.created_at && tag.last_status_at < 12.hours.ago)
    end

    # If we're processing an old status, this may register tags as being used now
    # as opposed to when the status was really published, but this is probably
    # not a big deal
    Trends.tags.register(status)

    # Update featured tags
    return if @tags.empty? || !status.distributable?

    @account.featured_tags.where(tag_id: @tags.pluck(:id)).find_each do |featured_tag|
      featured_tag.increment(status.created_at)
    end
  end

  def attach_mentions(status)
    @mentions.each do |mention|
      mention.status = status
      mention.save
    end
  end

  def attach_counts(status)
    likes = @status_parser.favourites_count
    shares = @status_parser.reblogs_count
    return if likes.nil? && shares.nil?

    status.status_stat.tap do |status_stat|
      status_stat.untrusted_reblogs_count = shares unless shares.nil?
      status_stat.untrusted_favourites_count = likes unless likes.nil?
      status_stat.save if status_stat.changed?
    end
  end

  def attach_quote(status)
    return if @quote.nil?

    @quote.status = status
    @quote.save

    embedded_quote = safe_prefetched_embed(@account, @status_parser.quoted_object, @json['context'])
    ActivityPub::VerifyQuoteService.new.call(@quote, fetchable_quoted_uri: @quote_uri, prefetched_quoted_object: embedded_quote, request_id: @options[:request_id], depth: @options[:depth])
  rescue Mastodon::RecursionLimitExceededError, Mastodon::UnexpectedResponseError, *Mastodon::HTTP_CONNECTION_ERRORS
    ActivityPub::RefetchAndVerifyQuoteWorker.perform_in(rand(30..600).seconds, @quote.id, @quote_uri, { 'request_id' => @options[:request_id] })
  end

  def process_tags
    return if @object['tag'].nil?

    as_array(@object['tag']).each do |tag|
      if equals_or_includes?(tag['type'], 'Hashtag')
        process_hashtag tag
      elsif equals_or_includes?(tag['type'], 'Mention')
        process_mention tag
      elsif equals_or_includes?(tag['type'], 'Emoji')
        process_emoji tag
      end
    end
  end

  def process_quote
    @quote_uri = @status_parser.quote_uri
    return if @quote_uri.blank?

    approval_uri = @status_parser.quote_approval_uri
    approval_uri = nil if unsupported_uri_scheme?(approval_uri) || TagManager.instance.local_url?(approval_uri)
    @quote = Quote.new(account: @account, approval_uri: approval_uri, legacy: @status_parser.legacy_quote?)
  end

  def process_hashtag(tag)
    return if tag['name'].blank?

    Tag.find_or_create_by_names(tag['name']) do |hashtag|
      @tags << hashtag unless @tags.include?(hashtag) || !hashtag.valid?
    end
  rescue ActiveRecord::RecordInvalid
    nil
  end

  def process_mention(tag)
    return if tag['href'].blank?

    account = account_from_uri(tag['href'])
    account = ActivityPub::FetchRemoteAccountService.new.call(tag['href'], request_id: @options[:request_id]) if account.nil?

    return if account.nil?

    @mentions << Mention.new(account: account, silent: false)
  rescue Mastodon::UnexpectedResponseError, *Mastodon::HTTP_CONNECTION_ERRORS
    @unresolved_mentions << tag['href']
  end

  def process_emoji(tag)
    return if skip_download?

    custom_emoji_parser = ActivityPub::Parser::CustomEmojiParser.new(tag)

    return if custom_emoji_parser.shortcode.blank? || custom_emoji_parser.image_remote_url.blank?

    emoji = CustomEmoji.find_by(shortcode: custom_emoji_parser.shortcode, domain: @account.domain)

    return unless emoji.nil? || custom_emoji_parser.image_remote_url != emoji.image_remote_url || (custom_emoji_parser.updated_at && custom_emoji_parser.updated_at >= emoji.updated_at)

    begin
      emoji ||= CustomEmoji.new(domain: @account.domain, shortcode: custom_emoji_parser.shortcode, uri: custom_emoji_parser.uri)
      emoji.image_remote_url = custom_emoji_parser.image_remote_url
      emoji.save
    rescue Seahorse::Client::NetworkingError => e
      Rails.logger.warn "Error storing emoji: #{e}"
    end
  end

  def process_attachments
    return [] if @object['attachment'].nil?

    media_attachments = []

    as_array(@object['attachment']).each do |attachment|
      media_attachment_parser = ActivityPub::Parser::MediaAttachmentParser.new(attachment)

      next if media_attachment_parser.remote_url.blank? || media_attachments.size >= Status::MEDIA_ATTACHMENTS_LIMIT

      begin
        media_attachment = MediaAttachment.create(
          account: @account,
          remote_url: media_attachment_parser.remote_url,
          thumbnail_remote_url: media_attachment_parser.thumbnail_remote_url,
          description: media_attachment_parser.description,
          focus: media_attachment_parser.focus,
          blurhash: media_attachment_parser.blurhash
        )

        media_attachments << media_attachment

        next if unsupported_media_type?(media_attachment_parser.file_content_type) || skip_download?

        media_attachment.download_file!
        media_attachment.download_thumbnail!
        media_attachment.save
      rescue Mastodon::UnexpectedResponseError, *Mastodon::HTTP_CONNECTION_ERRORS
        RedownloadMediaWorker.perform_in(rand(30..600).seconds, media_attachment.id)
      rescue Seahorse::Client::NetworkingError => e
        Rails.logger.warn "Error storing media attachment: #{e}"
        RedownloadMediaWorker.perform_async(media_attachment.id)
      end
    end

    media_attachments
  rescue Addressable::URI::InvalidURIError => e
    Rails.logger.debug { "Invalid URL in attachment: #{e}" }
    media_attachments
  end

  def process_poll
    poll_parser = ActivityPub::Parser::PollParser.new(@object)

    return unless poll_parser.valid?

    @account.polls.new(
      multiple: poll_parser.multiple,
      expires_at: poll_parser.expires_at,
      options: poll_parser.options,
      cached_tallies: poll_parser.cached_tallies,
      voters_count: poll_parser.voters_count
    )
  end

  def poll_vote?
    return false if replied_to_status.nil? || replied_to_status.preloadable_poll.nil? || !replied_to_status.local? || !replied_to_status.preloadable_poll.options.include?(@object['name'])

    poll_vote! unless replied_to_status.preloadable_poll.expired?

    true
  end

  def poll_vote!
    poll = replied_to_status.preloadable_poll
    already_voted = true

    with_redis_lock("vote:#{replied_to_status.poll_id}:#{@account.id}") do
      already_voted = poll.votes.exists?(account: @account)
      poll.votes.create!(account: @account, choice: poll.options.index(@object['name']), uri: object_uri)
    end

    increment_voters_count! unless already_voted
    ActivityPub::DistributePollUpdateWorker.perform_in(3.minutes, replied_to_status.id) unless replied_to_status.preloadable_poll.hide_totals?
  end

  def resolve_thread(status)
    return unless status.reply? && status.thread.nil? && Request.valid_url?(in_reply_to_uri)

    ThreadResolveWorker.perform_async(status.id, in_reply_to_uri, { 'request_id' => @options[:request_id] })
  end

  def resolve_unresolved_mentions(status)
    @unresolved_mentions.uniq.each do |uri|
      MentionResolveWorker.perform_in(rand(30...600).seconds, status.id, uri, { 'request_id' => @options[:request_id] })
    end
  end

  def fetch_replies(status)
    collection = @object['replies']
    return if collection.blank?

    replies = ActivityPub::FetchRepliesService.new.call(status.account.uri, collection, allow_synchronous_requests: false, request_id: @options[:request_id])
    return unless replies.nil?

    uri = value_or_id(collection)
    ActivityPub::FetchRepliesWorker.perform_async(status.id, uri, { 'request_id' => @options[:request_id] }) unless uri.nil?
  rescue => e
    Rails.logger.warn "Error fetching replies: #{e}"
  end

  def conversation_from_uri(uri)
    return nil if uri.nil?
    return Conversation.find_by(id: OStatus::TagManager.instance.unique_tag_to_local_id(uri, 'Conversation')) if OStatus::TagManager.instance.local_id?(uri)

    begin
      Conversation.find_or_create_by!(uri: uri)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      retry
    end
  end

  def replied_to_status
    return @replied_to_status if defined?(@replied_to_status)

    if in_reply_to_uri.blank?
      @replied_to_status = nil
    else
      @replied_to_status   = status_from_uri(in_reply_to_uri)
      @replied_to_status ||= status_from_uri(@object['inReplyToAtomUri']) if @object['inReplyToAtomUri'].present?
      @replied_to_status
    end
  end

  def in_reply_to_uri
    value_or_id(@object['inReplyTo'])
  end

  def converted_text
    [formatted_title, @status_parser.spoiler_text.presence, formatted_url].compact.join("\n\n")
  end

  def formatted_title
    "<h2>#{@status_parser.title}</h2>" if @status_parser.title.present?
  end

  def formatted_url
    linkify(@status_parser.url || @status_parser.uri)
  end

  def unsupported_media_type?(mime_type)
    mime_type.present? && !MediaAttachment.supported_mime_types.include?(mime_type)
  end

  def skip_download?
    return @skip_download if defined?(@skip_download)

    @skip_download ||= DomainBlock.reject_media?(@account.domain)
  end

  def reply_to_local?
    !replied_to_status.nil? && replied_to_status.account.local?
  end

  def related_to_local_activity?
    fetch? || followed_by_local_accounts? || requested_through_relay? ||
      responds_to_followed_account? || addresses_local_accounts?
  end

  def responds_to_followed_account?
    !replied_to_status.nil? && (replied_to_status.account.local? || replied_to_status.account.passive_relationships.exists?)
  end

  def addresses_local_accounts?
    return true if @options[:delivered_to_account_id]

    ActivityPub::TagManager.instance.uris_to_local_accounts((audience_to + audience_cc).uniq).exists?
  end

  def tombstone_exists?
    Tombstone.exists?(uri: object_uri)
  end

  def forward_for_reply
    return unless @status.distributable? && @json['signature'].present? && reply_to_local?

    ActivityPub::RawDistributionWorker.perform_async(Oj.dump(@json), replied_to_status.account_id, [@account.preferred_inbox_url])
  end

  def increment_voters_count!
    poll = replied_to_status.preloadable_poll

    unless poll.voters_count.nil?
      poll.voters_count = poll.voters_count + 1
      poll.save
    end
  rescue ActiveRecord::StaleObjectError
    poll.reload
    retry
  end

  def like_a_spam?
    (
      !@status.account.local? &&
      @status.account.followers_count <= 1 &&
      @status.account.created_at > 7.day.ago &&
      @mentions.count >= 1
    )
  end

  def convert_text(text_param)
    return '' if text_param.nil?
    text = text_param.to_s
    text = text.gsub(/<(br|p).*?>/,' ')
    text = ApplicationController.helpers.strip_tags(text)
    text = text.gsub(/[\x00-\x20\u3000]+/, ' ')
    text = text.strip
    text += ' '
    return text
  end
end
