# Copyright (c) 2009-2011 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib', 'activate_bundler'))

# Standard library dependencies
require 'optparse'
require 'fileutils'
require 'uri'

# Gem dependencies
require 'json'
require 'amqp'
require 'mq'
require 'yaml'
require 'right_agent'

# RightLink dependencies
lib_dir = File.join(File.dirname(__FILE__), '..', 'lib')
require File.normalize_path(File.join(lib_dir, 'instance', 'agent_config'))
require File.normalize_path(File.join(lib_dir, 'instance', 'instance_state'))

# This environment variable prevents our AMQP error handler from logging errors
# This is needed because when the fetch enroll result code first tries to connect
# the queue may not exist yet and thus we would log errors when that is the expected
# behavior
ENV['IGNORE_AMQP_FAILURES'] = '1'

module RightScale

  class AgentEnroller
    ENROLL_USER     = 'enrollment'
    ENROLL_PASSWORD = 'enrollment'
    RETRY_DEFAULT   = 3600*96 # by default, try to enroll for 96 hours max
    PRE_WAIT        = 5       # fixed time to wait between sending enroll request and reconnecting as the account user
    WAIT_MIN        = 4       # min time to wait for an enroll response before retry
    WAIT_MAX        = 64      # max time to wait for an enroll response before retry
    TERMINATE_ON_FAILURE_WINDOW = 45*60..60*60 # Terminate on failure if flag is set in user data AND failure
                                               # occurred between 45 and 60 minutes of the initial boot
    def self.run()
      client = AgentEnroller.new
      Kernel.exit client.enroll(client.parse_options)
    end

    def parse_options
      options = {}

      parser = OptionParser.new do |cli|
        cli.on('--root-dir DIR') do |d|
          options[:root_dir] = d
        end
        cli.on('-u', '--url URL') do |url|
          options[:url] = url
        end
        cli.on('-h', '--host HOST') do |host|
          options[:host] = host
        end
        cli.on('-p', '--port PORT') do |port|
          # only used for testing
          options[:port] = port
        end
        cli.on('-i', '--id ID') do |id|
          options[:id] = id.to_i
        end
        cli.on('-t', '--token TOKEN') do |token|
          options[:token] = token
        end
        cli.on('-d', '--or-die') do
          options[:die] = true
        end
        cli.on('-s', '--state FILE') do |file|
          options[:state] = file
        end
        cli.on('-r', '--retry TIME') do |time|
          options[:retry] = time.to_i
        end
        cli.on('--help') do
          usage
        end
      end

      begin
        parser.parse(ARGV)

        AgentConfig.root_dir = options[:root_dir]

        # Fill in some default options
        options[:state] ||= File.join(AgentConfig.agent_state_dir, 'enrollment_state.js')
        options[:die]   ||= false
        options[:retry] ||= RETRY_DEFAULT

        # Ensure all required options are present
        missing = []
        [:url, :id, :token].each  { |req| missing << req unless options[req] }
        raise ArgumentError, "Missing required option(s) #{missing.inspect}" unless missing.empty?

      rescue SystemExit => e
        # In case someone (e.g. RDoc usage) decided to bail
        raise e

      rescue Exception => e
        puts e.message + "\nUse --help for additional information"
        exit 1
      end

      return options
    end

    def enroll(options)
      url         = URI.parse(options[:url])
      token_id    = options[:id]
      auth_token  = options[:token]
      started_at  = Time.now
      retry_for   = options[:retry]
      retry_until = Time.at(started_at.to_i + retry_for)
      wait        = WAIT_MIN

      enroll_url          = url.dup
      enroll_url.user     = ENROLL_USER
      enroll_url.password = ENROLL_PASSWORD

      host = if !options[:host]
        url.host
      elsif options[:host][0,1] == ':' || options[:host][0,1] == ','
        "#{url.host}#{options[:host]}"
      else
        options[:host]
      end

      port = options[:port] || url.port || ::AMQP::PORT

      configure_logging

      create_state_file(options, started_at)

      while !@result && (Time.now < retry_until)
        t0 = Time.now

        begin
          Log.info("Requesting RightLink enrollment (token_id=#{token_id}; timestamp=#{t0.to_i})...")
          request_enrollment(t0, enroll_url, host, port, token_id, auth_token, WAIT_MIN)

          sleep(PRE_WAIT)

          Log.info("Fetching response (will wait #{wait} seconds)...")
          @result = fetch_enrollment_result(t0, url, host, port, token_id, auth_token, wait)

          if @result
            Log.info('Enrollment response received.')
          else
            raise StandardError, 'No enrollment response.'
          end

        rescue Interrupt => e
          Log.info('Interrupt received; abandoning enrollment.')
          return -2

        rescue Exception => e
          Log.error(e.message)

          check_shutdown(options, started_at)

          t1 = Time.now.utc
          dt = t1 - t0
          unless wait-dt <= 0
            Log.info("Sleeping for #{(wait-dt).to_i} more seconds.")
            sleep(wait-dt)
          end

          wait = [wait*2, WAIT_MAX].min
        end
      end

      if @result

        dir = AgentConfig.certs_dir
        # Ensure that the cert directory exists
        FileUtils.mkdir_p dir

        # Write the mapper cert, our cert, and our private kjey
        File.open(File.join(dir, 'mapper.cert'), "w") do |f|
          f.write(@result.mapper_cert)
        end
        File.open(File.join(dir, 'instance.cert'), "w") do |f|
          f.write(@result.id_cert)
        end
        File.open(File.join(dir, 'instance.key'), "w") do |f|
          f.write(@result.id_key)
        end

        return 0
      else
        Log.error("Could not complete enrollment after #{retry_for} sec; aborting!!!")
        return -1
      end
    end

    protected

    def configure_logging
      Log.program_name = 'RightLink'
      Log.log_to_file_only(false)
      Log.level = Logger::INFO
      FileUtils.mkdir_p(File.dirname(InstanceState::BOOT_LOG_FILE))
      Log.add_logger(Logger.new(File.open(InstanceState::BOOT_LOG_FILE, 'a')))
      Log.add_logger(Logger.new(STDOUT))
    end

    def predict_agent_identity(token_id, auth_token)
      public_token = SecureIdentity.derive(token_id, auth_token)
      return AgentIdentity.new('rs', 'instance', token_id, public_token).to_s
    end

    def predict_queue_name(token_id, token)
      return predict_agent_identity(token_id, token)
    end

    def shutdown_broker_and_em(broker, clean)
      Log.error("Could not (re)connect. Auth failure? Broker offline?") unless clean
      broker.close { EM.stop }
      true
    end

    # Connect to AMQP broker and post an enrollment request
    def request_enrollment(timestamp, url, host, port, token_id, token, wait)
      EM.run do
        options = {:host => host, :port => port, :user => url.user, :pass => url.password, :vhost => url.path}
        broker = HABrokerClient.new(serializer = nil, options)
        broker.connection_status(:one_off => wait) do |status|
          if status == :connected
            request = {
              :r_s_version    => AgentConfig.protocol_version.to_s,
              :agent_identity => predict_agent_identity(token_id, token),
              :timestamp      => timestamp.to_i.to_s,
              :token_id       => token_id,
              :verifier       => SecureIdentity.create_verifier(token_id, token, timestamp),
              :host           => options[:host],
              :port           => options[:port]
            }
            exchange = {:type => :direct, :name => "enrollment"}
            serializer = Serializer.new
            broker.publish(exchange, serializer.dump(request))
            shutdown_broker_and_em(broker, true)
          else
            shutdown_broker_and_em(broker, false)
          end
        end
      end
    end

    # Connect to AMQP broker, subscribe to our queue, and wait for an enrollment response
    def fetch_enrollment_result(timestamp, url, host, port, token_id, token, wait)
      retries = 0
      result = nil

      begin
        drain = false
        EM.run do
          options = {:host => host, :port => port, :user => url.user, :pass => url.password, :vhost => url.path}
          broker = HABrokerClient.new(serializer = nil, options)
          EM.add_timer(wait) { shutdown_broker_and_em(broker, true) }
          queue = {:name => predict_queue_name(token_id, token), :options => {:no_declare => true, :durable => true}}
          broker.subscribe(queue) do |b, msg|
            begin
              if drain
                Log.info("Discarding message (in drain mode after receiving a bad packet)")
              else
                Log.info("Received enrollment response via broker #{b}")
                result = EnrollmentResult.load(msg, token)
                if result && (result.timestamp.to_i != timestamp.to_i)
                  raise EnrollmentResult::IntegrityFailure.new("Wrong timestamp: expected #{timestamp.to_i}; "+
                                                               "got #{result.timestamp.to_i}")
                end
                shutdown_broker_and_em(broker, true)
              end
            rescue Exception => e
              Log.error("Received bad result packet", e)
              drain = true
            end
          end
        end
      rescue Exception => e
        # The initial calls to this function may fail because enroll has not yet created the queue
        if e.message =~ /NOT_FOUND - no queue/
          if (retries += 1) < 2
            host = host.dup.split(",").reverse.join(",") if host
            port = port.dup.split(",").reverse.join(",") if port && port.is_a?(String)
            Log.info("Retrying fetch using host #{host} port #{port} after queue not found error")
            sleep(1)
            retry
          end
        else
          raise e
        end
      end

      result
    end

    # Create a state file indicating the options we were invoked with in addition
    # to the time at which we first started to enroll. Intended for later use by
    # the RightLink agent or other components.
    def create_state_file(options, started_at)
      state_file  = options[:state]

      unless File.exists?(state_file)
        FileUtils.mkdir_p(File.dirname(state_file))
        File.open(state_file, 'w') do |f|
          state = options.merge(:started_at=>started_at.to_i)
          f.write(JSON.dump(state))
        end
      end
    end

    # Shutdown if the 'die' flag is set and enroll failed during initial boot
    # in the terminate on failure window.
    def check_shutdown(options, started_at)
      unless File.exists?(RightScale::InstanceState::STATE_FILE)
        elapsed_since_init_boot = Time.now - started_at
        if options[:die] && TERMINATE_ON_FAILURE_WINDOW.include?(elapsed_since_init_boot)
          Log.error("Shutting down after trying to enroll for #{elapsed_since_init_boot / 60} minutes")
          RightScale::Platform.controller.shutdown
          Kernel.exit(-1)
        end
      end
    end

    def usage
      puts <<EOF
Synopsis:
  RightLink Agent Enrollment Tool (enroll) - (c) 2009-2011 RightScale

  enroll is a command-line tool that retrieves agent configuration
  and credentials from RightScale servers in a secure manner

Usage:
  enroll.rb --root-dir DIR --url URL --host HOST --port PORT --id ID --token TOKEN
            [--state FILE --or-die --retry TIME]

  options:
    --root-dir DIR     Root directory of right_link
    --url, -u URL      AMQP connection URL (user/pass/host/port/vhost)
    --host, -h HOST    AMQP connection host:id comma-separated list
                       with first host defaulting to the one in URL, e.g.,
                      ":0,another_host:3"
    --port, -p PORT    AMQP connection port:id comma-separated list, corresponding
                       to host list; if only one port, it is used for all hosts
    --id, -i ID        Authenticate as agent ID
    --token, -t TOKEN  Use TOKEN to sign and encrypt AMQP messages
    --or-die, -d       Shutdown machine if not enrolled after 45 minutes
    --retry, -r TIME   Retry for TIME seconds before giving up permanently
    --state, -s FILE   Keep enrollment state (timestamps, etc) in FILE
EOF
      exit -2
    end

  end # AgentEnroller

end # RightScale

RightScale::AgentEnroller.run
