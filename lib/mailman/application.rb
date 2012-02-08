module Mailman
  # The main application class. Pass a block to {#new} to create a new app.
  class Application

    def self.run(&block)
      app = new(&block)
      app.run
      app
    end

    # @return [Router] the app's router
    attr_reader :router

    # @return [MessageProcessor] the app's message processor
    attr_reader :processor

    # Creates a new router, and sets up any routes passed in the block.
    # @param [Hash] options the application options
    # @option options [true,false] :graceful_death catch interrupt signal and don't die until end of poll
    # @param [Proc] block a block with routes
    def initialize(&block)
      @router = Mailman::Router.new
      @processor = MessageProcessor.new(:router => @router)
      instance_eval(&block)
    end

    # Sets the block to run if no routes match a message.
    def default(&block)
      @router.default_block = block
    end

    def watch_maildir
      require 'maildir'
      require 'fssm'

      Mailman.logger.info "Maildir receiver enabled (#{Mailman.config.maildir})."
      @maildir = Maildir.new(Mailman.config.maildir)

      Mailman.logger.debug "Monitoring the Maildir for new messages..."
      FSSM.monitor File.join(Mailman.config.maildir, 'new') do |monitor|
        monitor.create { |directory, filename| # a new message was delivered to new
          process_maildir
        }
      end
    end

    def retrieve_from_connection(connection)
      connection.connect
      connection.get_messages
      connection.disconnect
    rescue SystemCallError => e
      Mailman.logger.error e.message
    end

    def watch_connection(connection)
      polling = true

      if Mailman.config.graceful_death
        Signal.trap("INT") { polling = false }
      end

      loop do
        retrieve_from_connection(connection)

        break if !polling
        sleep Mailman.config.poll_interval
      end
    end

    def connection_configuration
      Mailman.config.pop3 || Mailman.config.imap
    end

    def create_connection(options)
      options = options.reverse_merge :processor => @processor
      if Mailman.config.pop3
        Receiver::POP3.new(options)
      else
        Receiver::IMAP.new(options)
      end
    end

    # Runs the application.
    def run
      Mailman.logger.info "Mailman v#{Mailman::VERSION} started"

      rails_env = File.join(Mailman.config.rails_root, 'config', 'environment.rb')
      if Mailman.config.rails_root && File.exist?(rails_env) && !(defined?(Rails) && Rails.env)
        Mailman.logger.info "Rails root found in #{Mailman.config.rails_root}, requiring environment..."
        require rails_env
      end

      if !Mailman.config.ignore_stdin && $stdin.fcntl(Fcntl::F_GETFL, 0) == 0 # we have stdin
        Mailman.logger.debug "Processing message from STDIN."
        @processor.process($stdin.read)
      elsif options = connection_configuration
        connection = create_connection(options)

        if Mailman.config.poll_interval > 0 # we should poll
          Mailman.logger.info "Polling enabled. Checking every #{Mailman.config.poll_interval} seconds."
          watch_connection(connection)
        else
          Mailman.logger.info 'Polling disabled. Checking for messages once.'
          retrieve_from_connection(connection)
        end
      elsif Mailman.config.maildir
        watch_maildir
      end
    end

    ##
    # List all message in Maildir new directory and process it
    #
    def process_maildir
      # Process messages queued in the new directory
      Mailman.logger.debug "Processing new message queue..."
      @maildir.list(:new).each do |message|
        @processor.process_maildir_message(message)
      end
    end

  end
end
