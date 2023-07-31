defmodule RealtimeWeb.Socket do
  defmacro __using__(opts) do
    quote do
      ## User API

      import Phoenix.Socket
      @behaviour Phoenix.Socket
      @before_compile Phoenix.Socket
      Module.register_attribute(__MODULE__, :phoenix_channels, accumulate: true)
      @phoenix_socket_options unquote(opts)

      ## Callbacks

      @behaviour Phoenix.Socket.Transport

      @doc false
      def child_spec(opts) do
        Phoenix.Socket.__child_spec__(__MODULE__, opts, @phoenix_socket_options)
      end

      @doc false
      def drainer_spec(opts) do
        Phoenix.Socket.__drainer_spec__(__MODULE__, opts, @phoenix_socket_options)
      end

      @doc false
      def connect(map), do: Phoenix.Socket.__connect__(__MODULE__, map, @phoenix_socket_options)

      @doc false
      def init(state), do: Phoenix.Socket.__init__(state)

      @doc false
      def handle_in(message, state) do
        # count incoming message depending on the messag event
        Phoenix.Socket.__in__(message, state)
      end

      @doc false
      def handle_info(
            {:socket_push, :text, [_, _, _, [_, [_ | event], _] | _]} = message,
            state
          )
          when event in ["broadcast", "presence_state", "presence_diff", "postgres_changes"] do
        # count outgoing message
        Phoenix.Socket.__info__(message, state)
      end

      @doc false
      def handle_info(message, state), do: Phoenix.Socket.__info__(message, state)

      @doc false
      def terminate(reason, state), do: Phoenix.Socket.__terminate__(reason, state)
    end
  end
end
