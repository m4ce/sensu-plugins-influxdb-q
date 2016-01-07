#!/usr/bin/env ruby
#
# check-influxdb-q.rb
#
# Author: Matteo Cerutti <matteo.cerutti@hotmail.co.uk>
#

require 'net/http'
require 'json'
require 'sensu-plugin/utils'
require 'sensu-plugin/check/cli'
require 'influxdb'
require 'jsonpath'
require 'dentaku'

class Hash
  def symbolize_recursive
    {}.tap do |h|
      self.each do |key, value|
      h[key.to_sym] = case value
          when Hash
            value.symbolize_recursive
          when Array
            value.map { |v| v.symbolize_recursive }
          else
            value
        end
      end
    end
  end
end

class CheckInfluxDbQ < Sensu::Plugin::Check::CLI
  include Sensu::Plugin::Utils

  option :query,
         :description => "Query to execute [e.g. SELECT DERIVATIVE(LAST(value), 1m) AS value FROM interface_rx WHERE type = 'if_errors' AND time > now() - 5m group by time(1m), instance, type fill(none)]",
         :short => "-q <QUERY>",
         :long => "--query <QUERY>",
         :required => true

  option :json_path,
         :description => "JSON path for value matching (docs at http://goessner.net/articles/JsonPath)",
         :short => "-j <PATH>",
         :long => "--json-path <PATH>",
         :required => true

  option :check_name,
         :description => "Check name (default: %{name}-%{tags.instance}-%{tags.type})",
         :long => "--check-name <CHECK_NAME>",
         :default => "%{name}-%{tags.instance}-%{tags.type}"

  option :msg,
         :description => "Message to use for OK/WARNING/CRITICAL, supports variable interpolation (e.g. %{tags.instance})",
         :short => "-m <MESSAGE>",
         :long => "--msg <MESSAGE>",
         :required => true

  option :database,
         :description => "InfluxDB database (default: collectd)",
         :long => "--database <DATABASE>",
         :default => "collectd"

  option :host,
         :description => "InfluxDB host (default: localhost)",
         :long => "--host <HOST>",
         :default => "localhost"

  option :port,
         :description => "InfluxDB port (default: 8086)",
         :long => "--port <PORT>",
         :proc => proc { |i| i.to_i },
         :default => 8086

  option :use_ssl,
         :description => "InfluxDB SSL (default: false)",
         :long => "--use-ssl",
         :default => false,
         :boolean => true

  option :host_field,
         :description => "InfluxDB measurement host field (default: host)",
         :long => "--host-field <FIELD>",
         :default => "host"

  option :warn,
         :description => "Warning expression (e.g. value >= 5)",
         :short => "-w <EXPR>",
         :long => "--warn <EXPR>",
         :default => nil

  option :crit,
         :description => "Critical expression (e.g. value >= 10)",
         :short => "-c <EXPR>",
         :long => "--crit <EXPR>",
         :default => nil

  option :dryrun,
         :description => "Do not send events to sensu client socket",
         :long => "--dryrun",
         :boolean => true,
         :default => false

  def initialize()
    super

    cfg = {
      :database => config[:database],
      :host => config[:host],
      :port => config[:port],
      :use_ssl => config[:use_ssl]
    }

    @calculator = Dentaku::Calculator.new
    @json_path = JsonPath.new(config[:json_path])
    @influxdb = InfluxDB::Client.new(cfg)

    # get list of hosts
    @clients = get_clients()
  end

  def send_client_socket(data)
    if config[:dryrun]
      puts data.inspect
    else
      sock = UDPSocket.new
      sock.send(data + "\n", 0, "127.0.0.1", 3030)
    end
  end

  def send_ok(check_name, source, msg)
    event = {"name" => check_name, "source" => source, "status" => 0, "output" => "OK: #{msg}", "handler" => config[:handler]}
    send_client_socket(event.to_json)
  end

  def send_warning(check_name, source, msg)
    event = {"name" => check_name, "source" => source, "status" => 1, "output" => "WARNING: #{msg}", "handler" => config[:handler]}
    send_client_socket(event.to_json)
  end

  def send_critical(check_name, source, msg)
    event = {"name" => check_name, "source" => source, "status" => 2, "output" => "CRITICAL: #{msg}", "handler" => config[:handler]}
    send_client_socket(event.to_json)
  end

  def send_unknown(check_name, source, msg)
    event = {"name" => check_name, "source" => source, "status" => 3, "output" => "UNKNOWN: #{msg}", "handler" => config[:handler]}
    send_client_socket(event.to_json)
  end

  def api_request(method, path, &blk)
    if not settings.has_key?('api')
      raise "api.json settings not found."
    end
    http = Net::HTTP.new(settings['api']['host'], settings['api']['port'])
    req = net_http_req_class(method).new(path)
    if settings['api']['user'] && settings['api']['password']
      req.basic_auth(settings['api']['user'], settings['api']['password'])
    end
    yield(req) if block_given?
    http.request(req)
  end

  def interpolate(string, hash)
    string.gsub(/%\{([^\}]*)\}/).each { |match| match[/^%{(.*)}$/, 1].split('.').inject(hash) { |h, k| h[(k.to_s == k.to_i.to_s) ? k.to_i : k.to_sym] } }
  end

  def get_clients()
    clients = []

    if req = api_request(:GET, "/clients")
      if req.code == '200'
        JSON.parse(req.body).each do |client|
          clients << client['name']
        end
      end
    end

    clients
  end

  def run()
    problems = 0

    @clients.each do |client|
      query = config[:query].gsub(" WHERE ", " WHERE #{config[:host_field]} = '#{client}' AND ")
      begin
        records = @influxdb.query(query)
        records.each do |record|
          value = @json_path.on(record).first

          record_s = record.symbolize_recursive
          check_name = "influxdb-q-#{interpolate(config[:check_name], record_s)}"
          msg = interpolate(config[:msg], record_s)

          if value != nil
            if config[:crit] and @calculator.evaluate(config[:crit], value: value)
              send_critical(check_name, client, "#{msg} - Value: #{value} (#{config[:crit]})")
            elsif config[:warn] and @calculator.evaluate(config[:warn], value: value)
              send_warning(check_name, client, "#{msg} - Value: #{value} (#{config[:warn]})")
            else
              send_ok(check_name, client, "#{msg} - Value: #{value}")
            end
          else
            send_unknown(check_name, client, "#{msg} - Value: N/A")
          end
        end
      rescue
        STDERR.puts($!)
        problems += 1
      end
    end

    if problems > 0
      message("Failed to run query for #{problems} clients")
      critical if config[:crit]
      warning
    else
      ok("Query executed successfully for #{@clients.size} clients")
    end
  end
end
