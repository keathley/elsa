defmodule Elsa.Supervisor do
  @moduledoc """
  Top-level supervisor that orchestrates all other components
  of the Elsa library. Allows for a single point of integration
  into your application supervision tree and configuration by way
  of a series of nested keyword lists

  Components not needed by a running application (if your application
  _only_ consumes messages from Kafka and never producers back to it)
  can be safely omitted from the configuration.
  """
  use Supervisor

  @doc """
  Defines a connection for locating the Elsa Registry process.
  """
  @spec registry(String.t() | atom()) :: atom()
  def registry(connection) do
    :"elsa_registry_#{connection}"
  end

  def via_name(registry, name) do
    {:via, Elsa.Registry, {registry, name}}
  end

  @doc """
  Starts the top-level Elsa supervisor and links it to the current process.
  Starts a brod client and a custom process registry by default
  and then conditionally starts and takes supervision of any
  brod group-based consumers or producer processes defined.

  ## Options

  * `:endpoints` - Required. Keyword list of kafka brokers. ex. `[localhost: 9092]`

  * `:connection` - Required. Atom used to track kafka connection.

  * `:config` - Optional. Client configuration options passed to brod.

  * `:producer` - Optional. Can be a single producer configuration of multiples in a list.

  * `:group_consumer` - Optional. Group consumer configuration.


  ## Producer Config

  * `:topic` - Required. Producer will be started for configured topic.

  * `:config` - Optional. Producer configuration options passed to `brod_producer`.


  ## Group Consumer Config

  * `:group` - Required. Name of consumer group.

  * `:topics` - Required. List of topics to subscribe to.

  * `:handler` - Required. Module that implements Elsa.Consumer.MessageHandler behaviour.

  * `:handler_init_args` - Optional. Any args to be passed to init function in handler module.

  * `:assignment_received_handler` - Optional. Arity 4 Function that will be called with any partition assignments.
     Return `:ok` to for assignment to be subscribed to.  Return `{:error, reason}` to stop subscription.
     Arguments are group, topic, partition, generation_id.

  * `:assignments_revoked_handler` - Optional. Zero arity function that will be called when assignments are revoked.
    All workers will be shutdown before callback is invoked and must return `:ok`.

  * `:direct_ack` - Optional. Boolean, `true` indicates to bypass `brod_group_coordinator` and ack directly to kafka.
    Defaults to `false`.

  * `:config` - Optional. Consumer configuration options passed to `brod_consumer`.


  ## Example

  ```
    Elsa.Supervisor.start_link([
      endpoints: [localhost: 9092],
      connection: :conn,
      producer: [topic: "topic1"],
      group_consumer: [
        group: "example-group",
        topics: ["topic1"],
        handler: ExampleHandler,
        config: [
          begin_offset: :earliest,
          offset_reset_policy: :reset_to_earliest
        ]
      ]
    ])
  ```

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(args) do
    opts =
      case Keyword.has_key?(args, :name) do
        true -> [name: Keyword.fetch!(args, :name)]
        false -> []
      end

    Supervisor.start_link(__MODULE__, args, opts)
  end

  def init(args) do
    connection = Keyword.fetch!(args, :connection)
    registry = registry(connection)

    children =
      [
        {Elsa.Registry, name: registry},
        start_client(args),
        start_producer(registry, Keyword.get(args, :producer)),
        start_group_consumer(connection, registry, Keyword.get(args, :group_consumer))
      ]
      |> List.flatten()

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp start_client(args) do
    connection = Keyword.fetch!(args, :connection)
    endpoints = Keyword.fetch!(args, :endpoints)
    config = Keyword.get(args, :config, [])

    {Elsa.Wrapper,
     mfa: {:brod_client, :start_link, [endpoints, connection, config]}, register: {registry(connection), :brod_client}}
  end

  defp start_group_consumer(_connection, _registry, nil), do: []

  defp start_group_consumer(connection, registry, args) do
    group_consumer_args =
      args
      |> Keyword.put(:registry, registry)
      |> Keyword.put(:connection, connection)
      |> Keyword.put(:name, via_name(registry, Elsa.Group.Supervisor))

    {Elsa.Group.Supervisor, group_consumer_args}
  end

  defp start_producer(_registry, nil), do: []

  defp start_producer(registry, args) do
    case Keyword.keyword?(args) do
      true -> producer_child_spec(registry, args)
      false -> Enum.map(args, fn entry -> producer_child_spec(registry, entry) end)
    end
  end

  defp producer_child_spec(registry, args) do
    producer_args =
      args
      |> Keyword.put(:registry, registry)

    {Elsa.Producer.Supervisor, producer_args}
  end
end