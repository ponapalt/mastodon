# frozen_string_literal: true

module JsonLdHelper
  include ContextHelper

  def equals_or_includes?(haystack, needle)
    haystack.is_a?(Array) ? haystack.include?(needle) : haystack == needle
  end

  def equals_or_includes_any?(haystack, needles)
    needles.any? { |needle| equals_or_includes?(haystack, needle) }
  end

  def first_of_value(value)
    value.is_a?(Array) ? value.first : value
  end

  def uri_from_bearcap(str)
    if str&.start_with?('bear:')
      Addressable::URI.parse(str).query_values['u']
    else
      str
    end
  end

  # The url attribute can be a string, an array of strings, or an array of objects.
  # The objects could include a mimeType. Not-included mimeType means it's text/html.
  def url_to_href(value, preferred_type = nil)
    value = [value] if value.is_a?(Hash)

    single_value = if value.is_a?(Array) && !value.first.is_a?(String)
                     value.find { |link| preferred_type.nil? || ((link['mimeType'].presence || 'text/html') == preferred_type) }
                   elsif value.is_a?(Array)
                     value.first
                   else
                     value
                   end

    if single_value.nil? || single_value.is_a?(String)
      single_value
    else
      single_value['href']
    end
  end

  def url_to_media_type(value, preferred_type = nil)
    value = [value] if value.is_a?(Hash)
    return unless value.is_a?(Array) && !value.first.is_a?(String)

    single_value = value.find { |link| preferred_type.nil? || ((link['mimeType'].presence || 'text/html') == preferred_type) }

    single_value['mediaType'] unless single_value.nil?
  end

  def as_array(value)
    if value.nil?
      []
    elsif value.is_a?(Array)
      value
    else
      [value]
    end
  end

  def value_or_id(value)
    return value if value.is_a?(String) || value.nil?

    value['id'] || value['url']
  end

  def supported_context?(json)
    !json.nil? && equals_or_includes?(json['@context'], ActivityPub::TagManager::CONTEXT)
  end

  def unsupported_uri_scheme?(uri)
    uri.nil? || !uri.start_with?('http://', 'https://')
  end

  def non_matching_uri_hosts?(base_url, comparison_url)
    return true if unsupported_uri_scheme?(comparison_url)

    needle = Addressable::URI.parse(comparison_url).host
    haystack = Addressable::URI.parse(base_url).host

    !haystack.casecmp(needle).zero?
  end

  def safe_prefetched_embed(account, object, context)
    return unless object.is_a?(Hash)

    # NOTE: Replacing the object's context by that of the parent activity is
    # not sound, but it's consistent with the rest of the codebase
    object = object.merge({ '@context' => context })

    return if value_or_id(first_of_value(object['attributedTo'])) != account.uri || non_matching_uri_hosts?(account.uri, object['id'])

    object
  end

  def canonicalize(json)
    graph = RDF::Graph.new << JSON::LD::API.toRdf(json, documentLoader: method(:load_jsonld_context))
    graph.dump(:normalize)
  end

  def compact(json)
    compacted = JSON::LD::API.compact(json.without('signature'), full_context, documentLoader: method(:load_jsonld_context))
    compacted['signature'] = json['signature']
    compacted
  end

  # Patches a JSON-LD document to avoid compatibility issues on redistribution
  #
  # Since compacting a JSON-LD document against Mastodon's built-in vocabulary
  # means other extension namespaces will be expanded, malformed JSON-LD
  # attributes lost, and some values “unexpectedly” compacted this method
  # patches the following likely sources of incompatibility:
  # - 'https://www.w3.org/ns/activitystreams#Public' being compacted to
  #   'as:Public' (for instance, pre-3.4.0 Mastodon does not understand
  #   'as:Public')
  # - single-item arrays being compacted to the item itself (`[foo]` being
  #   compacted to `foo`)
  #
  # It is not always possible for `patch_for_forwarding!` to produce a document
  # deemed safe for forwarding. Use `safe_for_forwarding?` to check the status
  # of the output document.
  #
  # @param original [Hash] The original JSON-LD document used as reference
  # @param compacted [Hash] The compacted JSON-LD document to be patched
  # @return [void]
  def patch_for_forwarding!(original, compacted)
    original.without('@context', 'signature').each do |key, value|
      next if value.nil? || !compacted.key?(key)

      compacted_value = compacted[key]
      if value.is_a?(Hash) && compacted_value.is_a?(Hash)
        patch_for_forwarding!(value, compacted_value)
      elsif value.is_a?(Array)
        compacted_value = [compacted_value] unless compacted_value.is_a?(Array)
        return nil if value.size != compacted_value.size

        compacted[key] = value.zip(compacted_value).map do |v, vc|
          if v.is_a?(Hash) && vc.is_a?(Hash)
            patch_for_forwarding!(v, vc)
            vc
          elsif v == 'https://www.w3.org/ns/activitystreams#Public' && vc == 'as:Public'
            v
          else
            vc
          end
        end
      elsif value == 'https://www.w3.org/ns/activitystreams#Public' && compacted_value == 'as:Public'
        compacted[key] = value
      end
    end
  end

  # Tests whether a JSON-LD compaction is deemed safe for redistribution,
  # that is, if it doesn't change its meaning to consumers that do not actually
  # handle JSON-LD, but rely on values being serialized in a certain way.
  #
  # See `patch_for_forwarding!` for details.
  #
  # @param original [Hash] The original JSON-LD document used as reference
  # @param compacted [Hash] The compacted JSON-LD document to be patched
  # @return [Boolean] Whether the patched document is deemed safe
  def safe_for_forwarding?(original, compacted)
    original.without('@context', 'signature').all? do |key, value|
      compacted_value = compacted[key]
      return false unless value.instance_of?(compacted_value.class)

      if value.is_a?(Hash)
        safe_for_forwarding?(value, compacted_value)
      elsif value.is_a?(Array)
        value.zip(compacted_value).all? do |v, vc|
          v.is_a?(Hash) ? (vc.is_a?(Hash) && safe_for_forwarding?(v, vc)) : v == vc
        end
      else
        value == compacted_value
      end
    end
  end

  # Fetch the resource given by uri.
  # @param uri [String]
  # @param id_is_known [Boolean]
  # @param on_behalf_of [nil, Account]
  # @param raise_on_error [Symbol<:all, :temporary, :none>] See {#fetch_resource_without_id_validation} for possible values
  def fetch_resource(uri, id_is_known, on_behalf_of = nil, raise_on_error: :none, request_options: {})
    unless id_is_known
      json = fetch_resource_without_id_validation(uri, on_behalf_of, raise_on_error: raise_on_error)

      return if !json.is_a?(Hash) || unsupported_uri_scheme?(json['id'])

      uri = json['id']
    end

    json = fetch_resource_without_id_validation(uri, on_behalf_of, raise_on_error: raise_on_error, request_options: request_options)
    json.present? && json['id'] == uri ? json : nil
  end

  # Fetch the resource given by uri
  #
  # If an error is raised, it contains the response and can be captured for handling like
  #
  #     begin
  #       fetch_resource_without_id_validation(uri, nil, true)
  #     rescue Mastodon::UnexpectedResponseError => e
  #       e.response
  #     end
  #
  # @param uri [String]
  # @param on_behalf_of [nil, Account]
  # @param raise_on_error [Symbol<:all, :temporary, :none>]
  #   - +:all+ - raise if response code is not in the 2xx range
  #   - +:temporary+ - raise if the response code is not an "unsalvageable error" like a 404
  #     (see {#response_error_unsalvageable} )
  #   - +:none+ - do not raise, return +nil+
  def fetch_resource_without_id_validation(uri, on_behalf_of = nil, raise_on_error: :none, request_options: {})
    on_behalf_of ||= Account.representative

    build_request(uri, on_behalf_of, options: request_options).perform do |response|
      raise Mastodon::UnexpectedResponseError, response if !response_successful?(response) && (
        raise_on_error == :all ||
        (!response_error_unsalvageable?(response) && raise_on_error == :temporary)
      )

      body_to_json(response.body_with_limit) if response.code == 200 && valid_activitypub_content_type?(response)
    end
  end

  def valid_activitypub_content_type?(response)
    return true if response.mime_type == 'application/activity+json'

    # When the mime type is `application/ld+json`, we need to check the profile,
    # but `http.rb` does not parse it for us.
    return false unless response.mime_type == 'application/ld+json'

    response.headers[HTTP::Headers::CONTENT_TYPE]&.split(';')&.map(&:strip)&.any? do |str|
      str.start_with?('profile="') && str[9...-1].split.include?('https://www.w3.org/ns/activitystreams')
    end
  end

  def body_to_json(body, compare_id: nil)
    json = body.is_a?(String) ? Oj.load(body, mode: :strict) : body

    return if compare_id.present? && json['id'] != compare_id

    json
  rescue Oj::ParseError
    nil
  end

  def response_successful?(response)
    (200...300).cover?(response.code)
  end

  def response_error_unsalvageable?(response)
    response.code == 501 || ((400...500).cover?(response.code) && ![401, 408, 429].include?(response.code))
  end

  def build_request(uri, on_behalf_of = nil, options: {})
    Request.new(:get, uri, **options).tap do |request|
      request.on_behalf_of(on_behalf_of) if on_behalf_of
      request.add_headers('Accept' => 'application/activity+json, application/ld+json')
    end
  end

  def load_jsonld_context(url, _options = {}, &block)
    json = Rails.cache.fetch("jsonld:context:#{url}", expires_in: 30.days, raw: true) do
      request = Request.new(:get, url)
      request.add_headers('Accept' => 'application/ld+json')
      request.perform do |res|
        raise JSON::LD::JsonLdError::LoadingDocumentFailed unless res.code == 200 && res.mime_type == 'application/ld+json'

        res.body_with_limit
      end
    end

    doc = JSON::LD::API::RemoteDocument.new(json, documentUrl: url)

    block ? yield(doc) : doc
  end
end
