# frozen_string_literal: true

module BackupRestore
  class S3BackupStore < BackupStore
    UPLOAD_URL_EXPIRES_AFTER_SECONDS ||= 6.hours.to_i

    delegate :abort_multipart, :presign_multipart_part, :list_multipart_parts,
      :complete_multipart, to: :s3_helper

    def initialize(opts = {})
      @s3_options = S3Helper.s3_options(SiteSetting)
      @s3_options.merge!(opts[:s3_options]) if opts[:s3_options]
    end

    def s3_helper
      @s3_helper ||= S3Helper.new(s3_bucket_name_with_prefix, '', @s3_options.clone)
    end

    def remote?
      true
    end

    def file(filename, include_download_source: false)
      obj = s3_helper.object(filename)
      create_file_from_object(obj, include_download_source) if obj.exists?
    end

    def delete_file(filename)
      obj = s3_helper.object(filename)

      if obj.exists?
        obj.delete
        reset_cache
      end
    end

    def download_file(filename, destination_path, failure_message = nil)
      s3_helper.download_file(filename, destination_path, failure_message)
    end

    def upload_file(filename, source_path, content_type)
      obj = s3_helper.object(filename)
      raise BackupFileExists.new if obj.exists?

      obj.upload_file(source_path, content_type: content_type)
      reset_cache
    end

    def generate_upload_url(filename)
      obj = s3_helper.object(filename)
      raise BackupFileExists.new if obj.exists?

      ensure_cors!
      presigned_url(obj.key, method: :put, expires_in: UPLOAD_URL_EXPIRES_AFTER_SECONDS)
    rescue Aws::Errors::ServiceError => e
      Rails.logger.warn("Failed to generate upload URL for S3: #{e.message.presence || e.class.name}")
      raise StorageError.new(e.message.presence || e.class.name)
    end

    def temporary_upload_path(file_name)
      FileStore::BaseStore.temporary_upload_path(file_name, folder_prefix: temporary_folder_prefix)
    end

    def temporary_folder_prefix
      folder_prefix = s3_helper.s3_bucket_folder_path.nil? ? "" : s3_helper.s3_bucket_folder_path

      if Rails.env.test?
        folder_prefix = File.join(folder_prefix, "test_#{ENV['TEST_ENV_NUMBER'].presence || '0'}")
      end

      folder_prefix
    end

    def create_multipart(file_name, content_type, metadata: {})
      obj = s3_helper.object(file_name)
      raise BackupFileExists.new if obj.exists?
      key = temporary_upload_path(file_name)
      s3_helper.create_multipart(key, content_type, metadata: metadata)
    end

    def move_existing_stored_upload(existing_external_upload_key, original_filename, secure, content_type = nil)
      s3_helper.copy(
        existing_external_upload_key,
        File.join(s3_helper.s3_bucket_folder_path, original_filename),
        options: { acl: "private", apply_metadata_to_destination: true }
      )
      s3_helper.delete_object(existing_external_upload_key)
    end

    private

    def unsorted_files
      objects = []

      s3_helper.list.each do |obj|
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

    def ensure_cors!
      rule = {
        allowed_headers: ["*"],
        allowed_methods: ["PUT"],
        allowed_origins: [Discourse.base_url_no_prefix],
        max_age_seconds: 3000
      }

      s3_helper.ensure_cors!([rule])
    end

    def cleanup_allowed?
      !SiteSetting.s3_disable_cleanup
    end

    def s3_bucket_name_with_prefix
      File.join(SiteSetting.s3_backup_bucket, RailsMultisite::ConnectionManagement.current_db)
    end

    def file_regex
      @file_regex ||= begin
        path = s3_helper.s3_bucket_folder_path || ""

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
