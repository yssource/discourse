# frozen_string_literal: true

class DiscourseAuthCookie
  V1 = "v1"
  TOKEN_SIZE = 32

  class InvalidCookie < StandardError; end
  class BadSignature < StandardError; end

  attr_reader *%i[token user_id trust_level timestamp version]

  def self.parse(raw_cookie, secret = Rails.application.secret_key_base)
    # v0 of the cookie was simply just the auth token
    return if raw_cookie.size <= TOKEN_SIZE

    data, sig = raw_cookie.split("|", 2)
    validate_signature!(data, sig, secret)

    parts = data.split(",")
    if data.first == V1
      version, token, user_id, trust_level, timestamp = parts
      cookie = new(
        token: token,
        user_id: user_id,
        trust_level: trust_level,
        timestamp: timestamp,
        version: V1
      )
      cookie
    end
  rescue InvalidCookie
    nil
  end

  def self.validate_signature!(data, sig, secret)
    data = data.to_s
    sig = sig.to_s
    if compute_signature(data, secret) != sig
      raise InvalidCookie.new
    end
  end

  def self.compute_signature(data, secret)
    OpenSSL::HMAC.hexdigest("sha256", secret, data)
  end

  def initialize(token:, user_id: nil, trust_level: nil, timestamp: nil, version: nil)
    @token = token
    @user_id = user_id.to_i if user_id
    @trust_level = trust_level.to_i if trust_level
    @timestamp = timestamp.to_i if timestamp
    @version = version || V1

    validate!
  end

  def validate!
    raise InvalidCookie.new if !token.presence || token.size != TOKEN_SIZE
  end

  def verify_signature!(sig, secret)
    if compute_signature(secret) != sig.to_s
      raise BadSignature.new
    end
  end

  def to_text(secret)
    parts = [version, token, user_id, trust_level, timestamp, compute_signature(secret)]
    parts.join(",")
  end

  private

  def compute_signature(secret)
    if vals = signed_values
      OpenSSL::HMAC.hexdigest("sha256", secret, vals.join(","))
    end
  end

  def signed_values
    if version == V1
      [token, user_id, trust_level, timestamp]
    end
  end
end
