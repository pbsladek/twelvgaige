defmodule Twelvgaige.Pattern.Condition do
  @moduledoc """
  Sandboxed condition evaluator for workflow readiness.

  Conditions are data expressions over round input and previous shot outputs.
  They do not call Elixir code, create atoms, or evaluate arbitrary functions.
  """

  alias Twelvgaige.Error

  defguardp identifier_char?(char)
            when (char >= ?a and char <= ?z) or
                   (char >= ?A and char <= ?Z) or
                   (char >= ?0 and char <= ?9) or
                   char in [?_, ?-]

  @type ast ::
          boolean()
          | {:not, ast()}
          | {:and, ast(), ast()}
          | {:or, ast(), ast()}
          | {:compare, [String.t()], atom(), term()}

  @spec validate(boolean() | String.t()) :: :ok | {:error, Error.t()}
  def validate(condition) when is_boolean(condition), do: :ok

  def validate(condition) when is_binary(condition) do
    case parse(condition) do
      {:ok, _ast} -> :ok
      {:error, _error} = error -> error
    end
  end

  def validate(condition) do
    {:error,
     Error.new(:condition_error, :unsupported_condition, "unsupported condition value",
       details: %{condition: inspect(condition)}
     )}
  end

  @spec evaluate(boolean() | String.t(), map()) :: {:ok, boolean()} | {:error, Error.t()}
  def evaluate(true, _context), do: {:ok, true}
  def evaluate(false, _context), do: {:ok, false}

  def evaluate(condition, context) when is_binary(condition) do
    with {:ok, ast} <- parse(condition) do
      eval(ast, normalize_context(context), condition)
    end
  end

  def evaluate(condition, _context) do
    {:error,
     Error.new(:condition_error, :unsupported_condition, "unsupported condition value",
       details: %{condition: inspect(condition)}
     )}
  end

  @spec parse(String.t()) :: {:ok, ast()} | {:error, Error.t()}
  def parse(condition) when is_binary(condition) do
    with {:ok, tokens} <- tokenize(condition),
         {:ok, ast, []} <- parse_or(tokens) do
      {:ok, ast}
    else
      {:ok, _ast, rest} ->
        {:error,
         Error.new(:condition_error, :unsupported_condition, "unexpected condition token",
           details: %{condition: condition, token: inspect(List.first(rest))}
         )}

      {:error, _error} = error ->
        error
    end
  end

  defp parse_or(tokens) do
    with {:ok, left, tokens} <- parse_and(tokens) do
      parse_or_tail(left, tokens)
    end
  end

  defp parse_or_tail(left, [:or | tokens]) do
    with {:ok, right, tokens} <- parse_and(tokens) do
      parse_or_tail({:or, left, right}, tokens)
    end
  end

  defp parse_or_tail(left, tokens), do: {:ok, left, tokens}

  defp parse_and(tokens) do
    with {:ok, left, tokens} <- parse_not(tokens) do
      parse_and_tail(left, tokens)
    end
  end

  defp parse_and_tail(left, [:and | tokens]) do
    with {:ok, right, tokens} <- parse_not(tokens) do
      parse_and_tail({:and, left, right}, tokens)
    end
  end

  defp parse_and_tail(left, tokens), do: {:ok, left, tokens}

  defp parse_not([:not | tokens]) do
    with {:ok, expr, tokens} <- parse_not(tokens) do
      {:ok, {:not, expr}, tokens}
    end
  end

  defp parse_not(tokens), do: parse_primary(tokens)

  defp parse_primary([:lparen | tokens]) do
    with {:ok, expr, [:rparen | tokens]} <- parse_or(tokens) do
      {:ok, expr, tokens}
    else
      {:ok, _expr, _tokens} ->
        parse_error("missing closing parenthesis", nil)

      {:error, _error} = error ->
        error
    end
  end

  defp parse_primary([{:boolean, value} | tokens]), do: {:ok, value, tokens}
  defp parse_primary(tokens), do: parse_comparison(tokens)

  defp parse_comparison(tokens) do
    with {:ok, path, tokens} <- parse_path(tokens),
         {:ok, op, tokens} <- parse_operator(tokens) do
      if op == :exists do
        {:ok, {:compare, path, op, nil}, tokens}
      else
        with {:ok, literal, tokens} <- parse_literal(tokens) do
          {:ok, {:compare, path, op, literal}, tokens}
        end
      end
    end
  end

  defp parse_path([token | tokens]) do
    with {:ok, root} <- segment_value(token),
         true <- root in ["input", "shots"],
         {:ok, segments, tokens} <- parse_path_segments(root, tokens),
         true <- valid_path?(root, segments) do
      {:ok, [root | segments], tokens}
    else
      false -> parse_error("invalid condition path", token)
      {:error, _reason} = error -> error
    end
  end

  defp parse_path(_tokens), do: parse_error("expected condition path", nil)

  defp parse_path_segments(root, [:dot, token | tokens]) do
    with {:ok, segment} <- segment_value(token),
         {:ok, segments, tokens} <- parse_path_segments(root, tokens) do
      {:ok, [segment | segments], tokens}
    end
  end

  defp parse_path_segments(_root, tokens), do: {:ok, [], tokens}

  defp valid_path?("input", segments), do: segments != []
  defp valid_path?("shots", segments), do: segments != []

  defp parse_operator([{:op, op} | tokens]), do: {:ok, op, tokens}
  defp parse_operator([:in | tokens]), do: {:ok, :in, tokens}
  defp parse_operator([:exists | tokens]), do: {:ok, :exists, tokens}
  defp parse_operator([token | _tokens]), do: parse_error("expected condition operator", token)
  defp parse_operator([]), do: parse_error("expected condition operator", nil)

  defp parse_literal([{:string, value} | tokens]), do: {:ok, value, tokens}
  defp parse_literal([{:number, value} | tokens]), do: {:ok, value, tokens}
  defp parse_literal([{:boolean, value} | tokens]), do: {:ok, value, tokens}
  defp parse_literal([:null | tokens]), do: {:ok, nil, tokens}

  defp parse_literal([:lbracket | tokens]) do
    parse_list(tokens, [])
  end

  defp parse_literal([token | _tokens]), do: parse_error("expected condition literal", token)
  defp parse_literal([]), do: parse_error("expected condition literal", nil)

  defp parse_list([:rbracket | tokens], acc), do: {:ok, Enum.reverse(acc), tokens}

  defp parse_list(tokens, acc) do
    with {:ok, literal, tokens} <- parse_literal(tokens) do
      case tokens do
        [:comma | tokens] -> parse_list(tokens, [literal | acc])
        [:rbracket | tokens] -> {:ok, Enum.reverse([literal | acc]), tokens}
        [token | _tokens] -> parse_error("expected comma or closing bracket", token)
        [] -> parse_error("missing closing bracket", nil)
      end
    end
  end

  defp eval(value, _context, _source) when is_boolean(value), do: {:ok, value}

  defp eval({:not, expr}, context, source) do
    with {:ok, value} <- eval(expr, context, source) do
      {:ok, not value}
    end
  end

  defp eval({:and, left, right}, context, source) do
    case eval(left, context, source) do
      {:ok, false} -> {:ok, false}
      {:ok, true} -> eval(right, context, source)
      {:error, _error} = error -> error
    end
  end

  defp eval({:or, left, right}, context, source) do
    case eval(left, context, source) do
      {:ok, true} -> {:ok, true}
      {:ok, false} -> eval(right, context, source)
      {:error, _error} = error -> error
    end
  end

  defp eval({:compare, path, :exists, _literal}, context, _source) do
    case fetch_path(context, path) do
      {:ok, _value} -> {:ok, true}
      :missing -> {:ok, false}
    end
  end

  defp eval({:compare, path, op, literal}, context, source) do
    case fetch_path(context, path) do
      {:ok, value} ->
        compare(value, op, literal, source)

      :missing ->
        {:error,
         Error.new(:condition_error, :condition_missing_path, "condition path is missing",
           details: %{condition: source, path: Enum.join(path, ".")}
         )}
    end
  end

  defp compare(value, :eq, literal, _source), do: {:ok, same_value?(value, literal)}
  defp compare(value, :neq, literal, _source), do: {:ok, not same_value?(value, literal)}

  defp compare(value, :in, literal, _source) when is_list(literal) do
    {:ok, Enum.any?(literal, &same_value?(value, &1))}
  end

  defp compare(_value, :in, _literal, source) do
    condition_error(source, "right side of in must be a list")
  end

  defp compare(value, op, literal, source) when op in [:gt, :gte, :lt, :lte] do
    with :ok <- comparable?(value, literal, source) do
      {:ok, ordered_compare(value, op, literal)}
    end
  end

  defp comparable?(left, right, _source) when is_number(left) and is_number(right), do: :ok
  defp comparable?(left, right, _source) when is_binary(left) and is_binary(right), do: :ok

  defp comparable?(_left, _right, source) do
    condition_error(source, "comparison requires two numbers or two strings")
  end

  defp ordered_compare(left, :gt, right), do: left > right
  defp ordered_compare(left, :gte, right), do: left >= right
  defp ordered_compare(left, :lt, right), do: left < right
  defp ordered_compare(left, :lte, right), do: left <= right

  defp same_value?(left, right) when is_number(left) and is_number(right), do: left == right
  defp same_value?(left, right), do: left == right

  defp fetch_path(context, ["input" | segments]) do
    do_fetch_path(Map.get(context, "input", %{}), segments)
  end

  defp fetch_path(context, ["shots", shot_id | segments]) do
    context
    |> Map.get("shots", %{})
    |> fetch_map_value(shot_id)
    |> case do
      {:ok, output} -> do_fetch_path(output, segments)
      :missing -> :missing
    end
  end

  defp fetch_path(_context, _path), do: :missing

  defp do_fetch_path(value, []), do: {:ok, value}

  defp do_fetch_path(%{} = map, [segment | rest]) do
    case fetch_map_value(map, segment) do
      {:ok, value} -> do_fetch_path(value, rest)
      :missing -> :missing
    end
  end

  defp do_fetch_path(_value, _segments), do: :missing

  defp fetch_map_value(%{} = map, key) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, Map.fetch!(map, key)}

      atom_key = existing_atom(key) ->
        if Map.has_key?(map, atom_key), do: {:ok, Map.fetch!(map, atom_key)}, else: :missing

      true ->
        :missing
    end
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp normalize_context(context) when is_map(context) do
    %{
      "input" => Map.get(context, "input", Map.get(context, :input, %{})),
      "shots" => Map.get(context, "shots", Map.get(context, :shots, %{}))
    }
  end

  defp tokenize(condition) do
    do_tokenize(condition, [])
  end

  defp do_tokenize(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_tokenize(<<char::utf8, rest::binary>>, acc) when char in [?\s, ?\n, ?\r, ?\t],
    do: do_tokenize(rest, acc)

  defp do_tokenize(<<"==", rest::binary>>, acc), do: do_tokenize(rest, [{:op, :eq} | acc])
  defp do_tokenize(<<"!=", rest::binary>>, acc), do: do_tokenize(rest, [{:op, :neq} | acc])
  defp do_tokenize(<<">=", rest::binary>>, acc), do: do_tokenize(rest, [{:op, :gte} | acc])
  defp do_tokenize(<<"<=", rest::binary>>, acc), do: do_tokenize(rest, [{:op, :lte} | acc])
  defp do_tokenize(<<">", rest::binary>>, acc), do: do_tokenize(rest, [{:op, :gt} | acc])
  defp do_tokenize(<<"<", rest::binary>>, acc), do: do_tokenize(rest, [{:op, :lt} | acc])
  defp do_tokenize(<<".", rest::binary>>, acc), do: do_tokenize(rest, [:dot | acc])
  defp do_tokenize(<<",", rest::binary>>, acc), do: do_tokenize(rest, [:comma | acc])
  defp do_tokenize(<<"[", rest::binary>>, acc), do: do_tokenize(rest, [:lbracket | acc])
  defp do_tokenize(<<"]", rest::binary>>, acc), do: do_tokenize(rest, [:rbracket | acc])
  defp do_tokenize(<<"(", rest::binary>>, acc), do: do_tokenize(rest, [:lparen | acc])
  defp do_tokenize(<<")", rest::binary>>, acc), do: do_tokenize(rest, [:rparen | acc])

  defp do_tokenize(<<"\"", rest::binary>>, acc) do
    case take_string(rest, []) do
      {:ok, value, rest} -> do_tokenize(rest, [{:string, value} | acc])
      {:error, reason} -> parse_error(reason, nil)
    end
  end

  defp do_tokenize(<<"-", next::utf8, _rest::binary>> = input, acc)
       when next >= ?0 and next <= ?9 do
    {number, rest} = take_number(input, "")

    case parse_number(number) do
      {:ok, value} -> do_tokenize(rest, [{:number, value} | acc])
      {:error, reason} -> parse_error(reason, number)
    end
  end

  defp do_tokenize(<<char::utf8, _rest::binary>> = input, acc)
       when char >= ?0 and char <= ?9 do
    {number, rest} = take_number(input, "")

    case parse_number(number) do
      {:ok, value} -> do_tokenize(rest, [{:number, value} | acc])
      {:error, reason} -> parse_error(reason, number)
    end
  end

  defp do_tokenize(<<char::utf8, _rest::binary>> = input, acc) when identifier_char?(char) do
    {identifier, rest} = take_identifier(input, "")
    do_tokenize(rest, [keyword_token(identifier) | acc])
  end

  defp do_tokenize(<<char::utf8, _rest::binary>>, _acc) do
    parse_error("unsupported condition character", <<char::utf8>>)
  end

  defp take_string(<<"\"", rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_string(<<"\\\"", rest::binary>>, acc), do: take_string(rest, [?\" | acc])
  defp take_string(<<"\\\\", rest::binary>>, acc), do: take_string(rest, [?\\ | acc])
  defp take_string(<<"\\n", rest::binary>>, acc), do: take_string(rest, [?\n | acc])
  defp take_string(<<"\\r", rest::binary>>, acc), do: take_string(rest, [?\r | acc])
  defp take_string(<<"\\t", rest::binary>>, acc), do: take_string(rest, [?\t | acc])
  defp take_string(<<"\\", _rest::binary>>, _acc), do: {:error, "unsupported string escape"}
  defp take_string(<<>>, _acc), do: {:error, "unterminated string literal"}

  defp take_string(<<char::utf8, rest::binary>>, acc) do
    take_string(rest, [<<char::utf8>> | acc])
  end

  defp take_number(<<char::utf8, rest::binary>>, acc)
       when char == ?- or char == ?. or (char >= ?0 and char <= ?9) do
    take_number(rest, acc <> <<char::utf8>>)
  end

  defp take_number(rest, acc), do: {acc, rest}

  defp parse_number(number) do
    cond do
      number in ["-", ".", "-."] ->
        {:error, "invalid number literal"}

      String.contains?(number, ".") ->
        case Float.parse(number) do
          {value, ""} -> {:ok, value}
          _other -> {:error, "invalid number literal"}
        end

      true ->
        case Integer.parse(number) do
          {value, ""} -> {:ok, value}
          _other -> {:error, "invalid number literal"}
        end
    end
  end

  defp take_identifier(<<char::utf8, rest::binary>>, acc) when identifier_char?(char) do
    take_identifier(rest, acc <> <<char::utf8>>)
  end

  defp take_identifier(rest, acc), do: {acc, rest}

  defp keyword_token("and"), do: :and
  defp keyword_token("or"), do: :or
  defp keyword_token("not"), do: :not
  defp keyword_token("in"), do: :in
  defp keyword_token("exists"), do: :exists
  defp keyword_token("true"), do: {:boolean, true}
  defp keyword_token("false"), do: {:boolean, false}
  defp keyword_token("null"), do: :null
  defp keyword_token(identifier), do: {:identifier, identifier}

  defp segment_value({:identifier, value}), do: {:ok, value}
  defp segment_value(:and), do: {:ok, "and"}
  defp segment_value(:or), do: {:ok, "or"}
  defp segment_value(:not), do: {:ok, "not"}
  defp segment_value(:in), do: {:ok, "in"}
  defp segment_value(:exists), do: {:ok, "exists"}
  defp segment_value({:boolean, true}), do: {:ok, "true"}
  defp segment_value({:boolean, false}), do: {:ok, "false"}
  defp segment_value(:null), do: {:ok, "null"}
  defp segment_value(token), do: parse_error("expected path segment", token)

  defp condition_error(condition, message) do
    {:error,
     Error.new(:condition_error, :unsupported_condition, message,
       details: %{condition: condition}
     )}
  end

  defp parse_error(message, token) do
    {:error,
     Error.new(:condition_error, :unsupported_condition, message,
       details: %{token: inspect(token)}
     )}
  end
end
