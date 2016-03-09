defmodule Absinthe.Relay.Node do
  @moduledoc """
  Support for global object identification.

  This module provides a macro `node` that should be used by schema
  authors to add required "object identification" support for object
  types, and to provide a unified interface for querying them.

  More information can be found at:
  - https://facebook.github.io/relay/docs/graphql-object-identification.html#content
  - https://facebook.github.io/relay/graphql/objectidentification.htm

  ## Interface

  Define a node interface for your schema, providing a type resolver that,
  given a resolved object can determine which node object type it belongs to.

  ```
  node interface do
    resolve_type fn
      %{age: _}, _ ->
        :person
      %{employee_count: _}, _ ->
        :business
      _, _ ->
        nil
    end
  end
  ```

  This will create an interface, `:node` that expects one field, `:id`, be
  defined -- and that the ID will be a global identifier.

  If you use the `node` macro to create your `object` types (see "Object" below),
  this can be easily done, layered on top of the standard object type definition
  style.

  ## Field

  The node field provides a unified interface to query for an object in the
  system using a global ID. The node field should be defined within your schema
  `query` and should provide a resolver that, given a map containing the object
  type identifier and internal, non-global ID (the incoming global ID will be
  parsed into these values for you automatically) can resolve the correct value.

  ```
  query do

    # ...

    node field do
      resolve fn
        %{type: :person, id: id}, _ ->
          {:ok, Map.get(@people, id)}
        %{type: :business, id: id}, _ ->
          {:ok, Map.get(@businesses, id)}
      end
    end

  end
  ```

  This creates a field, `:node`, with one argument: `:id`. This is expected to
  be a global ID and, once resolved, will result in a value whose type
  implements the `:node` interface.

  Here's how you easly create object types that can be looked up using this
  field:

  ## Object

  To play nicely with the `:node` interface and field, explained above, any
  object types need to implement the `:node` interface and generate a global
  ID as the value of its `:id` field. Using the `node` macro, you can easily do
  this while retaining the usual object type definition style.

  ```
  node object :person do
    field :name, :string
    field :age, :string
  end
  ```

  This will create an object type, `:person`, as you might expect. An `:id`
  field is created for you automatically, and this field generates a global ID;
  a Base64 string that's built using the object type name and the raw, internal
  identifier. All of this is handled for you automatically by prefixing your
  object type definition with `"node "`.

  The raw, internal value is retrieved using `default_id_fetcher/2` which just
  pattern matches an `:id` field from the resolved object. If you need to
  extract/build an internal ID via another method, just provide a function as
  an `:id_fetcher` option.

  For instance, assuming your raw internal IDs were stored as `:_id`, you could
  configure your object like this:

  ```
  node object :thing, id_fetcher: &my_custom_id_fetcher/2 do
    field :name, :string
  end
  ```
  """

  alias Absinthe.Schema.Notation

  @doc """
  Define a node interface, field, or object type for a schema. See the module documentation for more information.
  """
  defmacro node({:interface, _, _}, [do: block]) do
    do_interface(__CALLER__, block)
  end
  defmacro node({:field, _, _}, [do: block]) do
    do_field(__CALLER__, block)
  end
  defmacro node({:object, _, [identifier | rest]}, [do: block]) do
    do_object(__CALLER__, identifier, List.flatten(rest), block)
  end

  #
  # INTERFACE
  #

  # Add the node interface
  defp do_interface(env, block) do
    env
    |> Notation.recordable!(:interface)
    |> record_interface!(:node, [], block)
    Notation.desc_attribute_recorder(:node)
  end

  @doc false
  # Record the node interface
  def record_interface!(env, identifier, attrs, block) do
    Notation.record_interface!(
      env,
      identifier,
      Keyword.put_new(attrs, :description, "An object with an ID"),
      [interface_body, block]
    )
  end

  # An id field is automatically configured
  defp interface_body do
    quote do
      field :id, non_null(:id), description: "The id of the object."
    end
  end

  #
  # FIELD
  #

  # Add the node field
  defp do_field(env, block) do
    env
    |> Notation.recordable!(:field)
    |> record_field!(:node, [type: :node], block)
  end

  @doc false
  # Record the node field
  def record_field!(env, identifier, attrs, block) do
    Notation.record_field!(
      env,
      identifier,
      Keyword.put_new(attrs, :description, "Fetches an object given its ID"),
      [field_body, block]
    )
  end

  # An id arg is automatically added
  defp field_body do
    quote do
      @desc "The id of an object."
      arg :id, non_null(:id)

      private Absinthe, :resolve, &Absinthe.Relay.Node.resolve_with_global_id/3
    end
  end

  # Build a wrapper around a resolve function that
  # parses the global ID before invoking it
  def resolve_with_global_id(%{id: global_id}, info, designer_resolver) do
    case Absinthe.Relay.Node.from_global_id(global_id, info.schema) do
      {:ok, result} ->
        designer_resolver.(result, info)
      other ->
        other
    end
  end
  def resolve_with_global_id(_, info, designer_resolver) do
    designer_resolver.(%{}, info)
  end

  #
  # OBJECT
  #

  # Define a node object type
  defp do_object(env, identifier, attrs, block) do
    record_object!(env, identifier, attrs, block)
  end

  @doc false
  # Record a node object type
  def record_object!(env, identifier, attrs, block) do
    name = attrs[:name] || identifier |> Atom.to_string |> Absinthe.Utils.camelize
    Notation.record_object!(
      env,
      identifier,
      Keyword.delete(attrs, :id_fetcher),
      [object_body(name, attrs[:id_fetcher]), block]
    )
    Notation.desc_attribute_recorder(identifier)
  end

  # Automatically add:
  # - An id field that resolves to the generated global ID
  #   for an object of this type
  # - A declaration that this implements the node interface
  defp object_body(name, id_fetcher) do
    quote do
      @desc "The ID of an object"
      field :id, non_null(:id) do
        resolve Absinthe.Relay.Node.global_id_resolver(unquote(name), unquote(id_fetcher))
      end
      interface :node
    end
  end

  @doc """
  Parse a global ID, given a schema.

  ## Examples

  For a valid, existing type in `Schema`:

  ```
  iex> from_global_id("UGVyc29uOjE=", Schema)
  {:ok, %{type: :person, id: "1"}}
  ```

  For an invalid global ID value:

  ```
  iex> from_global_id("GHNF", Schema)
  {:error, "Could not decode ID value `GHNF'"}
  ```

  For a type that isn't in the schema:

  ```
  iex> from_global_id("Tm9wZToxMjM=", Schema)
  {:error, "Unknown type `Nope'"}
  ```

  For a type that is in the schema but isn't a node:

  ```
  iex> from_global_id("Tm9wZToxMjM=", Schema)
  {:error, "Type `Item' is not a valid node type"}
  ```
  """
  @spec from_global_id(binary, atom) :: {:ok, %{type: atom, id: binary}} | {:error, binary}
  def from_global_id(global_id, schema) do
    case Base.decode64(global_id) do
      {:ok, decoded} ->
        String.split(decoded, ":", parts: 2)
        |> do_from_global_id(decoded, schema)
      :error ->
        {:error, "Could not decode ID value `#{global_id}'"}
    end
  end

  defp do_from_global_id([type_name, id], _, schema) when byte_size(id) > 0 and byte_size(type_name) > 0 do
    case schema.__absinthe_type__(type_name) do
      nil ->
        {:error, "Unknown type `#{type_name}'"}
      %{__reference__: %{identifier: ident}, interfaces: interfaces} ->
        if Enum.member?(List.wrap(interfaces), :node) do
          {:ok, %{type: ident, id: id}}
        else
          {:error, "Type `#{type_name}' is not a valid node type"}
        end
    end
  end
  defp do_from_global_id(_, decoded, _schema) do
    {:error, "Could not extract value from decoded ID `#{decoded}'"}
  end

  @doc """
  Generate a global ID given a node type name and an internal (non-global) ID

  ## Examples

  ```
  iex> to_global_id("Person", "123")
  "UGVyc29uOjEyMw=="
  iex> to_global_id(:person, "123", SchemaWithPersonType)
  "UGVyc29uOjEyMw=="
  iex> to_global_id(:person, nil, SchemaWithPersonType)
  "No source non-global ID value given"
  ```
  """
  @spec to_global_id(atom | binary, integer | binary | nil) :: binary | nil
  def to_global_id(_node_type, nil) do
    nil
  end
  def to_global_id(node_type, source_id) when is_binary(node_type) do
    "#{node_type}:#{source_id}" |> Base.encode64
  end
  def to_global_id(node_type, source_id, schema) when is_atom(node_type) do
    case Absinthe.Schema.lookup_type(schema, node_type) do
      nil ->
        nil
      type ->
        to_global_id(type.name, source_id)
    end
  end

  @missing_internal_id_error "No source non-global ID value could be fetched from the source object"
  @doc false
  # The resolver for a global ID. If a type identifier instead of a type name
  # is used during field configuration, the type name needs to be looked up
  # during resolution.
  def global_id_resolver(identifier, nil)  do
    global_id_resolver(identifier, &default_id_fetcher/2)
  end
  def global_id_resolver(identifier, id_fetcher) when is_atom(identifier) do
    fn _obj, info ->
      type = Absinthe.Schema.lookup_type(info.schema, identifier)
      case id_fetcher.(info.source, info) do
        nil ->
          {:error, @missing_internal_id_error}
        internal_id ->
          {:ok, to_global_id(type.name, internal_id)}
      end
    end
  end
  def global_id_resolver(type_name, id_fetcher) when is_binary(type_name) do
    fn _, info ->
      case id_fetcher.(info.source, info) do
        nil ->
          {:error, @missing_internal_id_error}
        internal_id ->
          {:ok, to_global_id(type_name, internal_id)}
      end
    end
  end

  @doc """
  The default ID fetcher used to retrieve raw, non-global IDs from values.

  * Matches `:id` out of the value.
    * If it's `nil`, it returns `nil`
    * If it's not nil, it coerces it to a binary using `Kernel.to_string/1`

  ## Examples

  ```
  iex> default_id_fetcher(%{id: "foo"})
  "foo"
  iex> default_id_fetcher(%{id: 123})
  "123"
  iex> default_id_fetcher(%{id: nil})
  nil
  iex> default_id_fetcher(%{nope: "no_id"})
  nil
  ```
  """
  @spec default_id_fetcher(any, Execution.Field.t) :: nil | binary
  def default_id_fetcher(%{id: id}, _info) when is_nil(id), do: nil
  def default_id_fetcher(%{id: id}, _info), do: id |> to_string
  def default_id_fetcher(_, _), do: nil

end
