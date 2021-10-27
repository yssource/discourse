# frozen_string_literal: true

module BackupRestore
  class S3BackupStore < BackupStore
    UPLOAD_URL_EXPIRES_AFTER_SECONDS ||= 21_600 # 6 hours

    def initialize(opts = {})
      @s3_options = S3Helper.s3_options(SiteSetting)
      @s3_options.merge!(opts[:s3_options]) if opts[:s3_options]
      @s3_helper = S3Helper.new(s3_bucket_name_with_prefix, '', @s3_options.clone)
    end

    def remote?
      true
    end

    def file(filename, include_download_source: false)
      obj = @s3_helper.object(filename)
      create_file_from_object(obj, include_download_source) if obj.exists?
    end

    def delete_file(filename)
      obj = @s3_helper.object(filename)

      if obj.exists?
        obj.delete
        reset_cache
      end
    end

    def download_file(filename, destination_path, failure_message = nil)
      @s3_helper.download_file(filename, destination_path, failure_message)
    end

    def upload_file(filename, source_path, content_type)
      obj = @s3_helper.object(filename)
      raise BackupFileExists.new if obj.exists?

      obj.upload_file(source_path, content_type: content_type)
      reset_cache
    end

    def generate_upload_url(filename)
      obj = @s3_helper.object(filename)
      raise BackupFileExists.new if obj.exists?

      ensure_cors!
      presigned_url(obj.key, method: :put, expires_in: UPLOAD_URL_EXPIRES_AFTER_SECONDS)
    rescue Aws::Errors::ServiceError => e
      Rails.logger.warn("Failed to generate upload URL for S3: #{e.message.presence || e.class.name}")
      raise StorageError.new(e.message.presence || e.class.name)
    end

    def vacate_legacy_prefix
      legacy_s3_helper = S3Helper.new(s3_bucket_name_with_legacy_prefix, '', @s3_options.clone)
      bucket, prefix = s3_bucket_name_with_prefix.split('/', 2)
      legacy_keys = legacy_s3_helper.list
        .reject { |o| o.key.starts_with? prefix }
        .map { |o| o.key }
      legacy_keys.each do |legacy_key|
        @s3_helper.s3_client.copy_object({
          copy_source: File.join(bucket, legacy_key),
          bucket: bucket,
          key: File.join(prefix, legacy_key.split('/').last)
        })
        legacy_s3_helper.delete_object(legacy_key)
      end
    end

    def temporary_upload_path(file_name)
      folder_prefix = @s3_helper.s3_bucket_folder_path.nil? ? "" : @s3_helper.s3_bucket_folder_path

      # We don't want to use the original file name as it can contain special
      # characters, which can interfere with external providers operations and
      # introduce other unexpected behaviour.
      file_name_random = "#{SecureRandom.hex}#{File.extname(file_name)}"
      File.join(
        FileStore::BaseStore::TEMPORARY_UPLOAD_PREFIX,
        folder_prefix,
        SecureRandom.hex,
        file_name_random # this 1, no upload_path
      )
    end

    def create_multipart(file_name, content_type, metadata: {})
      key = temporary_upload_path(file_name)
      response = @s3_helper.s3_client.create_multipart_upload(
        acl: "private",
        bucket: @s3_helper.s3_bucket_name, # this 1
        key: key,
        content_type: content_type,
        metadata: metadata
      )
      { upload_id: response.upload_id, key: key }
    end

    def presign_multipart_part(upload_id:, key:, part_number:)
      presigned_url(
        key,
        method: :upload_part,
        expires_in: S3Helper::UPLOAD_URL_EXPIRES_AFTER_SECONDS,
        opts: {
          part_number: part_number,
          upload_id: upload_id
        }
      )
    end

    def list_multipart_parts(upload_id:, key:)
      @s3_helper.s3_client.list_parts(
        bucket: @s3_helper.s3_bucket_name,
        key: key,
        upload_id: upload_id
      )
    end

    def complete_multipart(upload_id:, key:, parts:)
      @s3_helper.s3_client.complete_multipart_upload(
        bucket: @s3_helper.s3_bucket_name, # this 1
        key: key,
        upload_id: upload_id,
        multipart_upload: {
          parts: parts
        }
      )
    end

    # changed from upload as param
    def move_existing_stored_upload(existing_external_upload_key, original_filename, secure, content_type = nil)
      @s3_helper.copy(
        existing_external_upload_key,
        File.join(@s3_helper.s3_bucket_folder_path, original_filename),
        options: { acl: "private", apply_metadata_to_destination: true }
      )
      delete_file_by_path(existing_external_upload_key)
    end

    def delete_file_by_path(path)
      # delete the object outright without moving to tombstone,
      # not recommended for most use cases
      @s3_helper.delete_object(path)
    end

    private

    def unsorted_files
      objects = []

      @s3_helper.list.each do |obj|
        if obj.key.match?(file_regex)
          objects << create_file_from_object(obj)
        end
      end

      objects
    rescue Aws::Errors::ServiceError => e
      Rails.logger.warn("Failed to list backups from S3: #{e.message.presence || e.class.name}")
      raise StorageError.new(e.message.presence || e.class.name)
    end

    def create_file_from_object(obj, include_download_source = false)
      expires = S3Helper::DOWNLOAD_URL_EXPIRES_AFTER_SECONDS
      BackupFile.new(
        filename: File.basename(obj.key),
        size: obj.size,
        last_modified: obj.last_modified,
        source: include_download_source ? presigned_url(obj, :get, expires) : nil
      )
    end

    def presigned_url(obj, method, expires_in_seconds)
      obj.presigned_url(method, expires_in: expires_in_seconds)
    end

    def presigned_url(
      key,
      method:,
      expires_in: S3Helper::UPLOAD_URL_EXPIRES_AFTER_SECONDS,
      opts: {}
    )
      signer = Aws::S3::Presigner.new(client: @s3_helper.s3_client)
      signer.presigned_url(
        method,
        {
          bucket: @s3_helper.s3_bucket_name,
          key: key,
          expires_in: expires_in,
        }.merge(opts)
      )
    end

    def ensure_cors!
      rule = {
        allowed_headers: ["*"],
        allowed_methods: ["PUT"],
        allowed_origins: [Discourse.base_url_no_prefix],
        max_age_seconds: 3000
      }

      @s3_helper.ensure_cors!([rule])
    end

    def cleanup_allowed?
      !SiteSetting.s3_disable_cleanup
    end

    def s3_bucket_name_with_prefix
      File.join(SiteSetting.s3_backup_bucket, RailsMultisite::ConnectionManagement.current_db)
    end

    def s3_bucket_name_with_legacy_prefix
      if Rails.configuration.multisite
        File.join(SiteSetting.s3_backup_bucket, "backups", RailsMultisite::ConnectionManagement.current_db)
      else
        SiteSetting.s3_backup_bucket
      end
    end

    def file_regex
      @file_regex ||= begin
        path = @s3_helper.s3_bucket_folder_path || ""

        if path.present?
          path = "#{path}/" unless path.end_with?("/")
          path = Regexp.quote(path)
        end

        /^#{path}[^\/]*\.t?gz$/i
      end
    end

    def free_bytes
      nil
    end
  end
end
