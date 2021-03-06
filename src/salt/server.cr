require "http/server"
require "logger"

require "./middlewares/common_logger"
require "./middlewares/show_exceptions"

module Salt
  # A Salt Server.
  #
  # ### Options
  # - `app`: a salt application to run
  # - `environment`: this selects the middleware that will be wrapped around. available are:
  #   - `development`: `Salt::CommonLogger`, `Salt::ShowExceptions`
  #   - `deployment`: `Salt::CommonLogger`
  #   - `none`: no extra middleware
  # - `host`: the host address to bind to
  # - `port`: the port to bind to (by default is `9898`)
  class Server
    property logger : ::Logger
    property options : Hash(String, String | Int32 | Bool)

    def initialize(**options)
      @options = parse_options(**options)
      @logger = default_logger
    end

    def run(@run_app : Salt::App)
      display_info
      run_server
    end

    def default_middlewares
      @middlewares ||= {
        "development" => [
          Salt::CommonLogger.as(Salt::App.class),
          Salt::ShowExceptions.as(Salt::App.class),
        ],
        "deployment" => [
          Salt::CommonLogger.as(Salt::App.class),
        ],
      }.as(Hash(String, Array(Salt::App.class)))
    end

    def run_server
      Signal::INT.trap { puts "\nCaught Ctrl+C and Goodbye."; exit }
      Signal::TERM.trap { puts "Caught kill"; exit }

      HTTP::Server.new(handlers: [handler]).listen(
        host: @options["host"].as(String),
        port: @options["port"].as(Int32),
        reuse_port: false
      )
    end

    private def handler
      Salt::Server::Handler.new(wrapped_app)
    end

    private def wrapped_app
      @wrapped_app ||= build_app(app).as(Salt::App)
    end

    private def app
      @app ||= Salt::Middlewares.to_app(run_app).as(Salt::App)
    end

    private def run_app
      @run_app.not_nil!
    end

    private def build_app(app : Salt::App) : Salt::App
      if middlewares = default_middlewares[@options["environment"]]?
        middlewares.each { |klass| app = klass.new(app) }
      end

      app
    end

    private def parse_options(**options)
      Hash(String, String | Int32 | Bool).new.tap do |obj|
        obj["environment"] = options.fetch(:environment, ENV["SALT_ENV"]? || "development")
        obj["host"] = options.fetch(:host, obj["environment"].to_s == "development" ? "localhost" : "0.0.0.0")
        obj["port"] = options.fetch(:port, 9898)

        ENV["SALT_ENV"] = obj["environment"].to_s
      end
    end

    private def default_logger
      logger = ::Logger.new(STDOUT)
      logger.formatter = ::Logger::Formatter.new do |severity, datetime, progname, message, io|
        io << "[" << Process.pid << "] " << message
      end

      logger
    end

    private def display_info
      @logger.info "Salt server starting ..."
      @logger.info "* Version #{Salt::VERSION} (Crystal #{Crystal::VERSION})"
      @logger.info "* Environment: #{@options["environment"]}"
      @logger.info "* Listening on http://#{@options["host"]}:#{@options["port"]}/"
      @logger.info "Use Ctrl-C to stop"
    end

    # Tranform Middlwares to HTTP::Handler
    class Handler
      include HTTP::Handler

      def initialize(@app : Salt::App)
      end

      def call(context)
        env = Salt::Environment.new(context)
        response = @app.call(env)

        status_code = response[0].as(Int32)
        headers = response[1].as(Hash(String, String))
        body = response[2].as(Array(String))

        context.response.status_code = status_code
        headers.each do |name, value|
          context.response.headers[name] = value
        end

        body.each do |line|
          context.response << line
        end
      end
    end
  end
end
