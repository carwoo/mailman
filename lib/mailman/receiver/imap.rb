module Mailman
  module Receiver
    # Receives messages using IMAP, and passes them to a {MessageProcessor}.
    class IMAP
      # @return [Net::IMAP] the IMAP connection
      attr_reader :connection

      # @param [Hash] options the receiver options
      # @option options [MessageProcessor] :processor the processor to pass new
      #   messages to
      # @option options [String] :server the server to connect to
      # @option options [Integer] :port the port to connect to
      # @option options [String] :username the username to authenticate with
      # @option options [String] :password the password to authenticate with
      # @option options [true,false] :ssl enable SSL
      def initialize(options={})
        @processor = options[:processor]
        @username = options[:username]
        @password = options[:password]
        @server = options[:server]
        @port = options.fetch(:port) { 143 }
        @ssl = options.fetch(:ssl) { false }

        @in_folder = options.fetch(:in_folder) { 'Inbox' }
        @processed_folder = options.fetch(:processed_folder) { 'Processed' }
        @error_folder = options.fetch(:error_folder) { 'Errors' }
      end

      # Open connection and login to server
      def connect
        @connection = Net::IMAP.new(@server, @port, @ssl)
        @connection.login(@username, @password)
      end

      def disconnect
        begin
          @connection.expunge
        rescue Net::IMAP::Error, ThreadError => e
          puts "Failed to expunge: #{e}"
        end
        @connection.logout
        @connection.disconnect unless @connection.disconnected?
      end

      # Retrieve messages from server
      def get_messages
        @connection.select(@in_folder)
        @connection.uid_search(['ALL']).each do |uid|
          message = @connection.uid_fetch(uid,'RFC822').first.attr['RFC822']
          @processor.process(message)
          add_to_processed_folder(uid) if @processed_folder
          # Mark message as deleted
          @connection.uid_store(uid, "+FLAGS", [:Seen, :Deleted])
        end
      end

      private

      def add_to_processed_folder(uid)
        create_mailbox(@processed_folder)
        @connection.uid_copy(uid, @processed_folder)
      end

      def create_mailbox(mailbox)
        unless @connection.list("", mailbox)
          @connection.create(mailbox)
        end
      end
    end
  end
end
