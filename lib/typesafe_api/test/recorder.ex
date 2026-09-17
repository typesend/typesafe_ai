defmodule TypeSafeAPI.Test.Recorder do
  @moduledoc false

  # Capture and replay for `TypeSafeAPI.Test.record/2` and `TypeSafeAPI.Test.replay/2`.
  #
  # Recording hooks in at two places because Req chooses the adapter itself:
  # `Req.merge/2` forces the adapter to `Req.Plug` whenever the options carry a
  # `:plug`, so a client that already has one (every `TypeSafeAPI.Test.client/1`)
  # is recorded by wrapping that plug, and a client that talks to the network is
  # recorded by wrapping the adapter.
  #
  # The wrapped adapter needs to know the fixture path and the adapter it wraps.
  # Req only lets `record/2` reach the request through `client.req_options`, and
  # of the fields `Req.merge/2` writes (`:method`, `:url`, `:headers`, `:body`,
  # `:adapter`, `:into`) plus Req's registered options, `:headers` is the only
  # carrier that is not already spoken for; `Req.Request.put_private/3` is not
  # reachable from options at all. So the two values ride in request headers,
  # and this module is careful about them in the one way that matters:
  #
  #   * the wrapped adapter is called with a request the headers were removed
  #     from, so they never reach the network, and
  #   * the request handed back to Req still carries them, so the retry step's
  #     `Req.Request.run_request/1` re-run finds them and attempt two is
  #     recorded through the same wrapped adapter rather than escaping to the
  #     real one.
  #
  # Nothing else about the request is recorded: no headers, so no
  # `Authorization` and no API key.

  @compile {:no_warn_undefined, Plug.Conn}

  @path_header "x-typesafe-record-to"
  @adapter_header "x-typesafe-record-adapter"
  @kept_headers ["content-type", "x-typesafe-request-id"]

  @doc "Header carrying the fixture path from the client to the adapter."
  def path_header, do: @path_header

  @doc "Header carrying the wrapped adapter module."
  def adapter_header, do: @adapter_header

  @doc "Match keys understood by `TypeSafeAPI.Test.replay/2`."
  def match_keys, do: [:method, :path, :body]

  # -- recording: adapter wrapper ----------------------------------------------

  @doc false
  def run(request) do
    {path, adapter, inner} = unpack(request)
    {inner, result} = adapter.run(inner)
    request = repack(inner, path, adapter)

    record(path, request_info(request), result)

    {request, result}
  end

  # Takes the recorder's own headers off the request that the wrapped adapter
  # will see, and returns them alongside it.
  defp unpack(request) do
    path = first_header(request, @path_header)
    adapter = request |> first_header(@adapter_header) |> to_adapter()

    inner =
      request
      |> Req.Request.delete_header(@path_header)
      |> Req.Request.delete_header(@adapter_header)

    {path, adapter, inner}
  end

  # Puts them back, so a retried run of this request records again instead of
  # falling through to the real adapter.
  defp repack(request, nil, _adapter), do: request

  defp repack(request, path, adapter) do
    request
    |> Req.Request.put_header(@path_header, path)
    |> Req.Request.put_header(@adapter_header, Atom.to_string(adapter))
  end

  defp first_header(request, name) do
    case Req.Request.get_header(request, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp to_adapter(nil), do: Req.Finch
  defp to_adapter(name), do: String.to_existing_atom(name)

  defp record(path, request, %Req.Response{status: status} = response) do
    append!(path, entry(request, status, headers(response.headers), response.body))
  end

  # A transport error never reached the server, so there is no response to
  # record and nothing a replayed test could reproduce from it.
  defp record(_path, _request, _exception), do: :ok

  defp request_info(request) do
    %{
      "method" => request.method |> to_string() |> String.upcase(),
      "path" => request.url.path || "/",
      "body" => decode(body_binary(request.body))
    }
  end

  defp body_binary(nil), do: nil
  defp body_binary(body) when is_binary(body), do: body
  defp body_binary(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp body_binary(_other), do: nil

  # -- recording: plug wrapper -------------------------------------------------

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, {plug, path}) do
    request = conn_request(conn)
    conn = call_plug(conn, plug)

    # A simulated transport error leaves no status behind, and there is nothing
    # a replayed test could reproduce from it.
    if is_integer(conn.status) do
      append!(path, entry(request, conn.status, headers(conn.resp_headers), conn.resp_body))
    end

    conn
  end

  defp call_plug(conn, fun) when is_function(fun, 1), do: fun.(conn)
  defp call_plug(conn, fun) when is_function(fun, 2), do: fun.(conn, [])
  defp call_plug(conn, {module, opts}), do: module.call(conn, module.init(opts))
  defp call_plug(conn, module) when is_atom(module), do: module.call(conn, module.init([]))

  defp conn_request(conn) do
    %{
      "method" => String.upcase(conn.method),
      "path" => conn.request_path,
      "body" => conn |> raw_body() |> decode()
    }
  end

  # What `Req.Test.raw_body/1` does, without calling it: that function is a
  # stub that raises when `plug` is missing, which makes the type checker treat
  # everything downstream of it as unreachable.
  defp raw_body(conn) do
    case conn.adapter do
      {_module, %{raw_body: raw_body}} ->
        raw_body

      other ->
        raise ArgumentError,
              "TypeSafeAPI.Test: cannot read the request body from this connection " <>
                "(adapter: #{inspect(other)}). Recording and replay need a client built " <>
                "with TypeSafeAPI.Test.client/1 or a live client."
    end
  end

  # -- fixture file ------------------------------------------------------------

  defp entry(request, status, headers, body) do
    %{
      "request" => request,
      "response" => %{"status" => status, "headers" => headers, "body" => decode(body)}
    }
  end

  defp headers(headers) when is_map(headers) do
    @kept_headers
    |> Map.new(fn name -> {name, headers[name]} end)
    |> drop_missing()
  end

  defp headers(headers) when is_list(headers) do
    headers
    |> Enum.filter(fn {name, _value} -> String.downcase(name) in @kept_headers end)
    |> Map.new(fn {name, value} -> {String.downcase(name), value} end)
  end

  defp drop_missing(headers) do
    headers
    |> Enum.flat_map(fn
      {_name, nil} -> []
      {name, [value | _]} -> [{name, value}]
      {name, value} -> [{name, value}]
    end)
    |> Map.new()
  end

  defp decode(nil), do: nil
  defp decode(""), do: nil

  defp decode(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode(body), do: body

  # A fixture is JSON Lines: one self-contained JSON object per line, in the
  # order the responses arrived. Appending is therefore a single `O(1)` write
  # rather than a read-modify-write of the whole file, which matters when a
  # fan-out records hundreds of entries. The global lock keeps two concurrent
  # writers from interleaving a partial line.
  defp append!(nil, _entry), do: :ok

  defp append!(path, entry) do
    line = JSON.encode!(entry) <> "\n"

    :global.trans({{__MODULE__, Path.expand(path)}, self()}, fn ->
      dir = Path.dirname(path)
      if dir != "", do: File.mkdir_p!(dir)
      File.write!(path, line, [:append])
    end)
  end

  @doc "Reads a fixture, raising with a helpful message when it is missing or malformed."
  def load!(path) do
    case File.read(path) do
      {:ok, contents} -> decode_entries(contents) || raise ArgumentError, malformed(path)
      {:error, reason} -> raise ArgumentError, unreadable(path, reason)
    end
  end

  defp malformed(path) do
    "TypeSafeAPI.Test.replay/2: #{inspect(path)} is not a fixture: it should hold one " <>
      "JSON recording per line. Record it with TypeSafeAPI.Test.record/2."
  end

  defp unreadable(path, reason) do
    "TypeSafeAPI.Test.replay/2: cannot read #{inspect(path)} " <>
      "(#{:file.format_error(reason)}). Record it with TypeSafeAPI.Test.record/2 first."
  end

  # JSON Lines, or a whole-file JSON array as fixtures recorded before 0.1.0
  # were written.
  defp decode_entries(contents) do
    case JSON.decode(contents) do
      {:ok, entries} when is_list(entries) -> entries
      _other -> decode_lines(contents)
    end
  end

  defp decode_lines(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.reduce_while([], fn line, acc ->
      case JSON.decode(line) do
        {:ok, entry} when is_map(entry) -> {:cont, [entry | acc]}
        _other -> {:halt, nil}
      end
    end)
    |> case do
      nil -> nil
      entries -> Enum.reverse(entries)
    end
  end

  # -- replay ------------------------------------------------------------------

  @doc false
  def replay_plug(conn, agent, match, path) do
    request = conn_request(conn)

    taken =
      Agent.get_and_update(agent, fn entries ->
        case take(entries, request, match) do
          {:ok, entry, rest} -> {{:ok, entry}, rest}
          :error -> {{:error, entries}, entries}
        end
      end)

    case taken do
      {:ok, entry} -> respond(conn, entry["response"])
      {:error, remaining} -> raise ArgumentError, no_match(path, request, remaining, match)
    end
  end

  # First match in recorded order, so a fixture with several entries for the
  # same method and path is served in the order it was written.
  defp take(entries, request, match) do
    case Enum.split_while(entries, &(not matches?(&1, request, match))) do
      {_before, []} -> :error
      {before, [entry | rest]} -> {:ok, entry, before ++ rest}
    end
  end

  defp matches?(%{"request" => recorded}, request, match) do
    Enum.all?(match, fn key -> recorded[to_string(key)] == request[to_string(key)] end)
  end

  defp matches?(_entry, _request, _match), do: false

  defp respond(conn, %{"status" => status} = response) do
    headers = response["headers"] || %{}

    headers
    |> Enum.reduce(conn, fn {name, value}, acc -> Plug.Conn.put_resp_header(acc, name, value) end)
    |> put_default_content_type(headers)
    |> Plug.Conn.send_resp(status, encode_body(response["body"]))
  end

  defp put_default_content_type(conn, headers) do
    if Map.has_key?(headers, "content-type") do
      conn
    else
      Plug.Conn.put_resp_header(conn, "content-type", "application/json")
    end
  end

  defp encode_body(nil), do: ""
  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body), do: JSON.encode!(body)

  # -- mismatch reporting ------------------------------------------------------

  defp no_match(path, request, remaining, match) do
    """
    TypeSafeAPI.Test.replay/2: no recording in #{inspect(path)} matches this request.

      matching on: #{inspect(match)}
      request:     #{request["method"]} #{request["path"]}
      body:        #{summary(request["body"])}

    #{closest(remaining, request)}
    #{unused(remaining)}

    Re-record the fixture with TypeSafeAPI.Test.record/2, or pass
    match: [:method, :path] to TypeSafeAPI.Test.replay/2 to ignore the body.
    """
  end

  defp closest(remaining, request) do
    case Enum.find(remaining, &same_route?(&1, request)) do
      nil ->
        "No unserved recording even has that method and path."

      %{"request" => recorded} ->
        """
        Closest unserved recording:
          request:     #{recorded["method"]} #{recorded["path"]}
          body:        #{summary(recorded["body"])}
          #{difference(recorded["body"], request["body"])}
        """
    end
  end

  defp same_route?(%{"request" => recorded}, request) do
    recorded["method"] == request["method"] and recorded["path"] == request["path"]
  end

  defp same_route?(_entry, _request), do: false

  defp difference(recorded, sent) when is_map(recorded) and is_map(sent) do
    case Enum.find(Map.keys(recorded) ++ Map.keys(sent), &(recorded[&1] != sent[&1])) do
      nil -> "bodies are equal; the difference is elsewhere"
      key -> "first difference: #{inspect(key)}"
    end
  end

  defp difference(_recorded, _sent), do: "bodies are not both JSON objects"

  defp unused([]), do: "Every recording in the fixture has already been served."

  defp unused(remaining) do
    listed =
      Enum.map_join(remaining, "\n", fn %{"request" => recorded} ->
        "  #{recorded["method"]} #{recorded["path"]} #{summary(recorded["body"])}"
      end)

    "Recordings still unserved:\n" <> listed
  end

  defp summary(nil), do: "(no body)"
  defp summary(body), do: inspect(body, limit: 8, printable_limit: 200)
end
