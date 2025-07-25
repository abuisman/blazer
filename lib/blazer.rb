# dependencies
require "chartkick"
require "safely/core"

# stdlib
require "csv"
require "digest/sha2"
require "json"
require "yaml"

# modules
require_relative "blazer/version"
require_relative "blazer/data_source"
require_relative "blazer/result"
require_relative "blazer/result_cache"
require_relative "blazer/run_statement"
require_relative "blazer/sharing"
require_relative "blazer/statement"

# adapters
require_relative "blazer/adapters/base_adapter"
require_relative "blazer/adapters/athena_adapter"
require_relative "blazer/adapters/bigquery_adapter"
require_relative "blazer/adapters/cassandra_adapter"
require_relative "blazer/adapters/drill_adapter"
require_relative "blazer/adapters/druid_adapter"
require_relative "blazer/adapters/elasticsearch_adapter"
require_relative "blazer/adapters/hive_adapter"
require_relative "blazer/adapters/ignite_adapter"
require_relative "blazer/adapters/influxdb_adapter"
require_relative "blazer/adapters/neo4j_adapter"
require_relative "blazer/adapters/opensearch_adapter"
require_relative "blazer/adapters/presto_adapter"
require_relative "blazer/adapters/salesforce_adapter"
require_relative "blazer/adapters/soda_adapter"
require_relative "blazer/adapters/spark_adapter"
require_relative "blazer/adapters/sql_adapter"
require_relative "blazer/adapters/snowflake_adapter"

# engine
require_relative "blazer/engine"

module Blazer
  class Error < StandardError; end
  class UploadError < Error; end
  class TimeoutNotSupported < Error; end

  # actionmailer optional
  autoload :CheckMailer, "blazer/check_mailer"
  # net/http optional
  autoload :SlackNotifier, "blazer/slack_notifier"
  # activejob optional
  autoload :RunStatementJob, "blazer/run_statement_job"

  class << self
    attr_accessor :audit
    attr_reader :time_zone
    attr_accessor :user_name
    attr_writer :user_class
    attr_writer :user_method
    attr_accessor :before_action
    attr_accessor :from_email
    attr_accessor :cache
    attr_accessor :transform_statement
    attr_accessor :transform_variable
    attr_accessor :check_schedules
    attr_accessor :anomaly_checks
    attr_accessor :forecasting
    attr_accessor :async
    attr_accessor :images
    attr_accessor :override_csp
    attr_accessor :slack_oauth_token
    attr_accessor :slack_webhook_url
    attr_accessor :mapbox_access_token
  end
  self.audit = true
  self.user_name = :name
  self.check_schedules = ["5 minutes", "1 hour", "1 day"]
  self.anomaly_checks = false
  self.forecasting = false
  self.async = false
  self.images = false
  self.override_csp = false

  VARIABLE_MESSAGE = "Variable cannot be used in this position"
  TIMEOUT_MESSAGE = "Query timed out :("
  TIMEOUT_ERRORS = [
    "canceling statement due to statement timeout", # postgres
    "canceling statement due to conflict with recovery", # postgres
    "cancelled on user's request", # redshift
    "canceled on user's request", # redshift
    "system requested abort", # redshift
    "maximum statement execution time exceeded" # mysql
  ]

  def self.time_zone=(time_zone)
    @time_zone = time_zone.is_a?(ActiveSupport::TimeZone) ? time_zone : ActiveSupport::TimeZone[time_zone.to_s]
  end

  def self.user_class
    if !defined?(@user_class)
      @user_class = settings.key?("user_class") ? settings["user_class"] : (User.name rescue nil)
    end
    @user_class
  end

  def self.user_method
    if !defined?(@user_method)
      @user_method = settings["user_method"]
      if user_class
        @user_method ||= "current_#{user_class.to_s.downcase.singularize}"
      end
    end
    @user_method
  end

  def self.settings
    @settings ||= begin
      path = Rails.root.join("config", "blazer.yml").to_s
      if File.exist?(path)
        YAML.safe_load(ERB.new(File.read(path)).result, aliases: true)
      else
        {}
      end
    end
  end

  def self.data_sources
    @data_sources ||= begin
      ds = Hash.new { |hash, key| raise Blazer::Error, "Unknown data source: #{key}" }
      settings["data_sources"].each do |id, s|
        ds[id] = Blazer::DataSource.new(id, s)
      end
      ds
    end
  end

  def self.sharing
    @sharing ||= begin
      sharing_settings = settings["sharing"] || {}
      Blazer::Sharing.new(**sharing_settings.symbolize_keys)
    end
  end

  def self.run_checks(schedule: nil)
    checks = Blazer::Check.includes(:query)
    checks = checks.where(schedule: schedule) if schedule
    checks.find_each do |check|
      next if check.state == "disabled"
      Safely.safely { run_check(check) }
    end
  end

  def self.run_check(check)
    tries = 1

    ActiveSupport::Notifications.instrument("run_check.blazer", check_id: check.id, query_id: check.query.id, state_was: check.state) do |instrument|
      # try 3 times on timeout errors
      statement = check.query.statement_object
      data_source = statement.data_source

      while tries <= 3
        result = data_source.run_statement(statement, refresh_cache: true, check: check, query: check.query)
        if result.timed_out?
          Rails.logger.info "[blazer timeout] query=#{check.query.name}"
          tries += 1
          sleep(10)
        elsif result.error.to_s.start_with?("PG::ConnectionBad")
          data_source.reconnect
          Rails.logger.info "[blazer reconnect] query=#{check.query.name}"
          tries += 1
          sleep(10)
        else
          break
        end
      end

      begin
        check.reload # in case state has changed since job started
        check.update_state(result)
      rescue ActiveRecord::RecordNotFound
        # check deleted
      end

      # TODO use proper logfmt
      Rails.logger.info "[blazer check] query=#{check.query.name} state=#{check.state} rows=#{result.rows.try(:size)} error=#{result.error}"

      # should be no variables
      instrument[:statement] = statement.bind_statement
      instrument[:data_source] = data_source
      instrument[:state] = check.state
      instrument[:rows] = result.rows.try(:size)
      instrument[:error] = result.error
      instrument[:tries] = tries
    end
  end

  def self.send_failing_checks
    emails = {}
    slack_channels = {}

    Blazer::Check.includes(:query).where(state: ["failing", "error", "timed out", "disabled"]).find_each do |check|
      check.split_emails.each do |email|
        (emails[email] ||= []) << check
      end
      check.split_slack_channels.each do |channel|
        (slack_channels[channel] ||= []) << check
      end
    end

    emails.each do |email, checks|
      Safely.safely do
        Blazer::CheckMailer.failing_checks(email, checks).deliver_now
      end
    end

    slack_channels.each do |channel, checks|
      Safely.safely do
        Blazer::SlackNotifier.failing_checks(channel, checks)
      end
    end
  end

  def self.slack?
    slack_oauth_token.present? || slack_webhook_url.present?
  end

  # TODO show warning on invalid access token
  def self.maps?
    mapbox_access_token.present? && mapbox_access_token.start_with?("pk.")
  end

  def self.uploads?
    settings.key?("uploads")
  end

  def self.uploads_connection
    raise "Empty url for uploads" unless settings.dig("uploads", "url")
    Blazer::UploadsConnection.connection
  end

  def self.uploads_schema
    settings.dig("uploads", "schema") || "uploads"
  end

  def self.uploads_table_name(name)
    uploads_connection.quote_table_name("#{uploads_schema}.#{name}")
  end

  def self.adapters
    @adapters ||= {}
  end

  def self.register_adapter(name, adapter)
    adapters[name] = adapter
  end

  def self.anomaly_detectors
    @anomaly_detectors ||= {}
  end

  def self.register_anomaly_detector(name, &anomaly_detector)
    anomaly_detectors[name] = anomaly_detector
  end

  def self.forecasters
    @forecasters ||= {}
  end

  def self.register_forecaster(name, &forecaster)
    forecasters[name] = forecaster
  end

  def self.archive_queries
    raise "Audits must be enabled to archive" unless Blazer.audit
    raise "Missing status column - see https://github.com/ankane/blazer#23" unless Blazer::Query.column_names.include?("status")

    viewed_query_ids = Blazer::Audit.where("created_at > ?", 90.days.ago).group(:query_id).count.keys.compact
    Blazer::Query.active.where.not(id: viewed_query_ids).update_all(status: "archived")
  end

  # private
  def self.monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

require_relative "blazer/adapters"
require_relative "blazer/anomaly_detectors"
require_relative "blazer/forecasters"
