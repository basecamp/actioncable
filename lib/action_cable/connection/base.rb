require 'action_dispatch/http/request'

module ActionCable
  module Connection
    # For every websocket the cable server is accepting, a Connection object will be instantiated. This instance becomes the parent
    # of all the channel subscriptions that are created from there on. Incoming messages are then routed to these channel subscriptions
    # based on an identifier sent by the cable consumer. The Connection itself does not deal with any specific application logic beyond
    # authentication and authorization.
    #
    # Here's a basic example:
    #
    #   module ApplicationCable
    #     class Connection < ActionCable::Connection::Base
    #       identified_by :current_user
    #
    #       after_connect do
    #         self.current_user = find_verified_user
    #         logger.add_tags current_user.name
    #       end
    #
    #       after_disconnect do
    #         # Any cleanup work needed when the cable connection is cut.
    #       end
    #
    #       protected
    #         def find_verified_user
    #           if current_user = User.find_by_identity cookies.signed[:identity_id]
    #             current_user
    #           else
    #             reject_unauthorized_connection
    #           end
    #         end
    #     end
    #   end
    #
    # First, we declare that this connection can be identified by its current_user. This allows us later to be able to find all connections
    # established for that current_user (and potentially disconnect them if the user was removed from an account). You can declare as many
    # identification indexes as you like. Declaring an identification means that a attr_accessor is automatically set for that key.
    #
    # Second, we rely on the fact that the websocket connection is established with the cookies from that domain being sent along. This makes
    # it easy to use signed cookies that were set when logging in via a web interface to authorize the websocket connection.
    #
    # Finally, we add a tag to the connection-specific logger with name of the current user to easily distinguish their messages in the log.
    #
    # Pretty simple, eh?
    class Base
      include Identification
      include InternalChannel
      include Authorization
      include Callbacks
      include HijackingProtection

      attr_reader :server, :env
      delegate :worker_pool, :pubsub, to: :server

      attr_reader :logger

      def initialize(server, env)
        @server, @env = server, env

        @logger = new_tagged_logger

        @websocket      = ActionCable::Connection::WebSocket.new(env)
        @heartbeat      = ActionCable::Connection::Heartbeat.new(self)
        @subscriptions  = ActionCable::Connection::Subscriptions.new(self)
        @message_buffer = ActionCable::Connection::MessageBuffer.new(self)

        @started_at = Time.now
      end

      # Called by the server when a new websocket connection is established. This configures the callbacks intended for overwriting by the user.
      # This method should not be called directly. Rely on the #connect (and #disconnect) callback instead.
      def process
        logger.info started_request_message

        if websocket.possible?
          websocket.on(:open)    { |event| send_async :on_open   }
          websocket.on(:message) { |event| on_message event.data }
          websocket.on(:close)   { |event| send_async :on_close  }

          respond_to_successful_request
        else
          respond_to_invalid_request
        end
      end

      # Data received over the cable is handled by this method. It's expected that everything inbound is encoded with JSON.
      # The data is routed to the proper channel that the connection has subscribed to.
      def receive(data_in_json)
        if websocket.alive?
          subscriptions.execute_command ActiveSupport::JSON.decode(data_in_json)
        else
          logger.error "Received data without a live websocket (#{data.inspect})"
        end
      end

      # Send raw data straight back down the websocket. This is not intended to be called directly. Use the #transmit available on the
      # Channel instead, as that'll automatically address the correct subscriber and wrap the message in JSON.
      def transmit(data)
        websocket.transmit data
      end

      # Close the websocket connection.
      def close
        logger.error "Closing connection"
        websocket.close
      end

      # Invoke a method on the connection asynchronously through the pool of thread workers.
      def send_async(method, *arguments)
        worker_pool.async.invoke(self, method, *arguments)
      end

      # Return a basic hash of statistics for the connection keyed with `identifier`, `started_at`, and `subscriptions`.
      # This can be returned by a health check against the connection.
      def statistics
        { identifier: connection_identifier, started_at: @started_at, subscriptions: subscriptions.identifiers }
      end


      protected
        # The request that initiated the websocket connection is available here. This gives access to the environment, cookies, etc.
        def request
          @request ||= begin
            environment = Rails.application.env_config.merge(env) if defined?(Rails.application) && Rails.application
            ActionDispatch::Request.new(environment || env)
          end
        end

        # The cookies of the request that initiated the websocket connection. Useful for performing authorization checks.
        def cookies
          request.cookie_jar
        end

        # The session of the request that initiated the websocket connection. Useful for performing server-side validations.
        def session
          @session ||= begin
            if defined?(Rails.application) && Rails.application
              Rails.application.config.session_store.new(request, Rails.application.config.session_options).load_session(request.env).last
            else
              request.session
            end
          end
        end


      private
        attr_reader :websocket
        attr_reader :heartbeat, :subscriptions, :message_buffer

        def on_open
          server.add_connection(self)

          run_callbacks :connect

          subscribe_to_internal_channel
          heartbeat.start

          message_buffer.process!
        rescue ActionCable::Connection::Authorization::UnauthorizedError
          respond_to_invalid_request
          close
        end

        def on_message(message)
          message_buffer.append message
        end

        def on_close
          logger.info finished_request_message

          server.remove_connection(self)

          subscriptions.unsubscribe_from_all
          unsubscribe_from_internal_channel
          heartbeat.stop

          run_callbacks :disconnect
        end


        def respond_to_successful_request
          websocket.rack_response
        end

        def respond_to_invalid_request
          logger.info finished_request_message
          [ 404, { 'Content-Type' => 'text/plain' }, [ 'Page not found' ] ]
        end


        # Tags are declared in the server but computed in the connection. This allows us per-connection tailored tags.
        def new_tagged_logger
          TaggedLoggerProxy.new server.logger,
            tags: server.config.log_tags.map { |tag| tag.respond_to?(:call) ? tag.call(request) : tag.to_s.camelize }
        end

        def started_request_message
          'Started %s "%s"%s for %s at %s' % [
            request.request_method,
            request.filtered_path,
            websocket.possible? ? ' [Websocket]' : '',
            request.ip,
            Time.now.to_default_s ]
        end

        def finished_request_message
          'Finished "%s"%s for %s at %s' % [
            request.filtered_path,
            websocket.possible? ? ' [Websocket]' : '',
            request.ip,
            Time.now.to_default_s ]
        end
    end
  end
end
