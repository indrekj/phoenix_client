defmodule PhoenixClient.Socket do
  use GenServer

  require Logger

  @heartbeat_interval 30_000
  @reconnect_interval 60_000
  @default_transport PhoenixClient.Transports.Websocket

  alias PhoenixClient.Message

  def child_spec({opts, genserver_opts}) do
    %{
      id: genserver_opts[:id] || __MODULE__,
      start: {__MODULE__, :start_link, [opts, genserver_opts]}
    }
  end

  def child_spec(opts) do
    child_spec({opts, []})
  end

  def start_link(opts, genserver_opts \\ []) do
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  @spec connected?(pid) :: boolean
  def connected?(pid) do
    GenServer.call(pid, :status) == :connected
  end

  @doc false
  def push(pid, %Message{} = message) do
    GenServer.call(pid, {:push, message})
  end

  @doc false
  def channel_join(pid, channel, topic, params) do
    GenServer.call(pid, {:channel_join, channel, topic, params})
  end

  @doc false
  def channel_leave(pid, channel, topic) do
    GenServer.call(pid, {:channel_leave, channel, topic})
  end

  ## Callbacks
  @impl true
  def init(opts) do
    :crypto.start()
    :ssl.start()

    transport = opts[:transport] || @default_transport

    json_library = Keyword.get(opts, :json_library, Jason)
    reconnect? = Keyword.get(opts, :reconnect?, true)

    protocol_vsn = Keyword.get(opts, :vsn, "2.0.0")
    serializer = Message.serializer(protocol_vsn)

    uri =
      opts
      |> Keyword.get(:url, "")
      |> URI.parse()

    params = Keyword.get(opts, :params, %{})

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.put("vsn", protocol_vsn)
      |> Map.merge(params)
      |> URI.encode_query()

    url =
      uri
      |> Map.put(:query, query)
      |> to_string()

    opts = Keyword.put_new(opts, :headers, [])
    heartbeat_interval = opts[:heartbeat_interval] || @heartbeat_interval
    reconnect_interval = opts[:reconnect_interval] || @reconnect_interval

    transport_opts =
      Keyword.get(opts, :transport_opts, [])
      |> Keyword.put(:sender, self())

    send(self(), :connect)

    {:ok,
     %{
       opts: opts,
       url: url,
       json_library: json_library,
       params: params,
       channels: %{},
       reconnect: reconnect?,
       heartbeat_interval: heartbeat_interval,
       reconnect_interval: reconnect_interval,
       reconnect_timer: nil,
       status: :disconnected,
       serializer: serializer,
       transport: transport,
       transport_opts: transport_opts,
       transport_pid: nil,
       queue: :queue.new(),
       ref: 0
     }}
  end

  @impl true
  def handle_call({:push, %Message{} = message}, _from, state) do
    {push, state} = push_message(message, state)
    {:reply, push, state}
  end

  @impl true
  def handle_call(
        {:channel_join, channel_pid, topic, params},
        _from,
        %{channels: channels} = state
      ) do
    case Map.get(channels, topic) do
      nil ->
        monitor_ref = Process.monitor(channel_pid)
        message = Message.join(topic, params)
        {push, state} = push_message(message, state)
        channels = Map.put(channels, topic, {channel_pid, monitor_ref})
        {:reply, {:ok, push}, %{state | channels: channels}}

      {pid, _topic} ->
        {:reply, {:error, {:already_joined, pid}}, state}
    end
  end

  @impl true
  def handle_call({:channel_leave, _channel, topic}, _from, %{channels: channels} = state) do
    case Map.get(channels, topic) do
      nil ->
        {:reply, :error, state}

      {_channel_pid, monitor_ref} ->
        Process.demonitor(monitor_ref)
        message = Message.leave(topic)
        {push, state} = push_message(message, state)
        channels = Map.drop(channels, [topic])
        {:reply, {:ok, push}, %{state | channels: channels}}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_info({:connected, transport_pid}, %{transport_pid: transport_pid} = state) do
    :erlang.send_after(state.heartbeat_interval, self(), :heartbeat)
    {:noreply, %{state | status: :connected}}
  end

  def handle_info({:disconnected, reason, transport_pid}, %{transport_pid: transport_pid} = state) do
    {:noreply, close(reason, state)}
  end

  @impl true
  def handle_info(:heartbeat, %{status: :connected} = state) do
    ref = state.ref + 1

    %Message{topic: "phoenix", event: "heartbeat", ref: ref}
    |> transport_send(state)

    :erlang.send_after(state.heartbeat_interval, self(), :heartbeat)
    {:noreply, %{state | ref: ref}}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    {:noreply, state}
  end

  # New Messages from the transport_pid come in here
  @impl true
  def handle_info({:receive, message}, state) do
    transport_receive(message, state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, %{status: :connected} = state) do
    state =
      case :queue.out(state.queue) do
        {:empty, _queue} ->
          state

        {{:value, message}, queue} ->
          transport_send(message, state)
          :erlang.send_after(100, self(), :flush)
          %{state | queue: queue}
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    :erlang.send_after(100, self(), :flush)
    {:noreply, state}
  end

  @impl true
  def handle_info(:connect, %{transport: transport, transport_opts: opts} = state) do
    case transport.open(state.url, opts) do
      {:ok, transport_pid} ->
        {:noreply, %{state | transport_pid: transport_pid, reconnect_timer: nil}}

      {:error, reason} ->
        {:noreply, close(reason, state)}
    end
  end

  # Handle Errors in the transport and channels
  @impl true
  def handle_info(
        {:closed, reason, transport_pid},
        %{transport_pid: transport_pid} = state
      ) do
    {:noreply, close(reason, state)}
  end

  # Channel went down
  @impl true
  def handle_info({:DOWN, _monitor_ref, :process, pid, _reason}, %{channels: channels} = state) do
    down_channel =
      Enum.find(channels, fn {_topic, {channel_pid, _}} ->
        channel_pid == pid
      end)

    case down_channel do
      nil ->
        {:noreply, state}

      {topic, _} ->
        message = Message.leave(topic)
        {_push, state} = push_message(message, state)
        channels = Map.drop(channels, [topic])
        {:noreply, %{state | channels: channels}}
    end
  end

  defp transport_receive(message, %{
         channels: channels,
         serializer: serializer,
         json_library: json_library
       }) do
    decoded = Message.decode!(serializer, message, json_library)

    case Map.get(channels, decoded.topic) do
      nil -> :noop
      {channel_pid, _} -> send(channel_pid, decoded)
    end
  end

  defp transport_send(message, %{
         transport_pid: pid,
         serializer: serializer,
         json_library: json_library
       }) do
    send(pid, {:send, Message.encode!(serializer, message, json_library)})
  end

  defp close(reason, %{channels: channels, reconnect_timer: nil} = state) do
    state = %{state | status: :disconnected, channels: %{}}

    message = %Message{event: close_event(reason), payload: %{reason: reason}}

    for {_topic, {channel_pid, _}} <- channels do
      send(channel_pid, message)
    end

    if state.reconnect do
      timer_ref = Process.send_after(self(), :connect, state.reconnect_interval)
      %{state | reconnect_timer: timer_ref}
    else
      state
    end
  end

  defp close_event(:normal), do: "phx_close"
  defp close_event(_), do: "phx_error"

  defp push_message(message, state) do
    ref = state.ref + 1
    push = %{message | ref: to_string(ref)}
    send(self(), :flush)
    state = %{state | ref: ref, queue: :queue.in(push, state.queue)}
    {push, state}
  end
end
