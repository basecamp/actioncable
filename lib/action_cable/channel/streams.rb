module ActionCable
  module Channel
    # Streams allow channels to route broadcastings to the subscriber. A broadcasting is an discussed elsewhere a pub/sub queue where any data
    # put into it is automatically sent to the clients that are connected at that time. It's purely an online queue, though. If you're not
    # streaming a broadcasting at the very moment it sends out an update, you'll not get that update when connecting later.
    #
    # Most commonly, the streamed broadcast is sent straight to the subscriber on the client-side. The channel just acts as a connector between
    # the two parties (the broadcaster and the channel subscriber). Here's an example of a channel that allows subscribers to get all new
    # comments on a given page:
    #
    #   class CommentsChannel < ApplicationCable::Channel
    #     def follow(data)
    #       stream_from "comments_for_#{data['recording_id']}"
    #     end
    #
    #     def unfollow
    #       stop_all_streams
    #     end
    #   end
    #
    # So the subscribers of this channel will get whatever data is put into the, let's say, `comments_for_45` broadcasting as soon as it's put there.
    # That looks like so from that side of things:
    #
    #   ActionCable.server.broadcast "comments_for_45", author: 'DHH', content: 'Rails is just swell'
    #
    # If you don't just want to parlay the broadcast unfiltered to the subscriber, you can supply a callback that let's you alter what goes out.
    # Example below shows how you can use this to provide performance introspection in the process:
    #
    #   class ChatChannel < ApplicationCable::Channel
    #    def subscribed
    #      @room = Chat::Room[params[:room_number]]
    #
    #      stream_from @room.channel, -> (message) do
    #        message = ActiveSupport::JSON.decode(m)
    #
    #        if message['originated_at'].present?
    #          elapsed_time = (Time.now.to_f - message['originated_at']).round(2)
    #
    #          ActiveSupport::Notifications.instrument :performance, measurement: 'Chat.message_delay', value: elapsed_time, action: :timing
    #          logger.info "Message took #{elapsed_time}s to arrive"
    #        end
    #
    #        transmit message
    #      end
    #    end
    #
    # You can stop streaming from all broadcasts by calling #stop_all_streams.
    module Streams
      extend ActiveSupport::Concern

      included do
        on_unsubscribe :stop_all_streams
      end

      # Start streaming from the named <tt>broadcasting</tt> pubsub queue. Optionally, you can pass a <tt>callback</tt> that'll be used
      # instead of the default of just transmitting the updates straight to the subscriber.
      def stream_from(broadcasting, callback = nil)
        callback ||= default_stream_callback(broadcasting)

        streams << [ broadcasting, callback ]
        pubsub.subscribe broadcasting, &callback

        logger.info "#{self.class.name} is streaming from #{broadcasting}"
      end

      def stop_all_streams
        streams.each do |broadcasting, callback|
          pubsub.unsubscribe_proc broadcasting, callback
          logger.info "#{self.class.name} stopped streaming from #{broadcasting}"
        end
      end

      private
        delegate :pubsub, to: :connection

        def streams
          @_streams ||= []
        end

        def default_stream_callback(broadcasting)
          -> (message) do
            transmit ActiveSupport::JSON.decode(message), via: "streamed from #{broadcasting}"
          end
        end
    end
  end
end
