port_file = System.fetch_env!("TWELVGAIGE_E2E_OLLAMA_PORT_FILE")

{:ok, listener} =
  :gen_tcp.listen(0, [
    :binary,
    packet: :raw,
    active: false,
    reuseaddr: true,
    ip: {127, 0, 0, 1}
  ])

{:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
File.write!(port_file, "#{port}\n")

read_request = fn socket ->
  receive_more = fn receive_more, buffered ->
    case :binary.match(buffered, "\r\n\r\n") do
      {header_end, 4} ->
        header_size = header_end + 4
        <<headers::binary-size(header_size), body::binary>> = buffered

        content_length =
          case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, headers, capture: :all_but_first) do
            [value] -> String.to_integer(value)
            _missing -> 0
          end

        if byte_size(body) >= content_length do
          {:ok, headers}
        else
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, data} -> receive_more.(receive_more, buffered <> data)
            error -> error
          end
        end

      :nomatch ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> receive_more.(receive_more, buffered <> data)
          error -> error
        end
    end
  end

  receive_more.(receive_more, "")
end

respond = fn socket, status, body ->
  reason = if status == 200, do: "OK", else: "Not Found"

  :gen_tcp.send(socket, [
    "HTTP/1.1 #{status} #{reason}\r\n",
    "content-type: application/json\r\n",
    "content-length: #{byte_size(body)}\r\n",
    "connection: close\r\n",
    "\r\n",
    body
  ])
end

serve = fn serve ->
  {:ok, socket} = :gen_tcp.accept(listener)

  case read_request.(socket) do
    {:ok, "POST /api/chat " <> _rest} ->
      respond.(
        socket,
        200,
        ~s({"message":{"role":"assistant","content":"local fixture response"},"done":true,"done_reason":"stop","prompt_eval_count":1,"eval_count":1})
      )

    {:ok, _request} ->
      respond.(socket, 404, ~s({"error":"fixture endpoint not found"}))

    {:error, _reason} ->
      :ok
  end

  :gen_tcp.close(socket)
  serve.(serve)
end

serve.(serve)
