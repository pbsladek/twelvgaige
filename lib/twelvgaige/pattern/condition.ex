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

  @type parse_opt :: {:authoring_aliases?, boolean()}

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

  @spec parse(String.t(), [parse_opt()]) :: {:ok, ast()} | {:error, Error.t()}
  def parse(condition, opts \\ [])

  def parse(condition, opts) when is_binary(condition) and is_list(opts) do
    with {:ok, tokens} <- tokenize(condition),
         {:ok, ast, []} <- parse_or(tokens, opts) do
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

  @spec shot_references(boolean() | String.t(), [parse_opt()]) ::
          {:ok, [String.t()]} | {:error, Error.t()}
  def shot_references(condition, opts \\ [])
  def shot_references(condition, _opts) when is_boolean(condition), do: {:ok, []}

  def shot_references(condition, opts) when is_binary(condition) do
    with {:ok, ast} <- parse(condition, opts) do
      {:ok, ast |> collect_shot_references() |> Enum.uniq() |> Enum.sort()}
    end
  end

  @spec rewrite_shot_reference(String.t(), String.t(), String.t(), [parse_opt()]) ::
          {:ok, String.t()} | {:error, Error.t()}
  def rewrite_shot_reference(condition, old_id, new_id, opts \\ [])

  def rewrite_shot_reference(condition, old_id, new_id, opts)
      when is_binary(condition) and is_binary(old_id) and is_binary(new_id) do
    with {:ok, ast} <- parse(condition, opts) do
      {:ok, ast |> rewrite_shot_ast(old_id, new_id) |> render()}
    end
  end

  @spec render(ast()) :: String.t()
  def render(ast), do: render(ast, 0)

  defp parse_or(tokens, opts) do
    with {:ok, left, tokens} <- parse_and(tokens, opts) do
      parse_or_tail(left, tokens, opts)
    end
  end

  defp parse_or_tail(left, [:or | tokens], opts) do
    with {:ok, right, tokens} <- parse_and(tokens, opts) do
      parse_or_tail({:or, left, right}, tokens, opts)
    end
  end

  defp parse_or_tail(left, tokens, _opts), do: {:ok, left, tokens}

  defp parse_and(tokens, opts) do
    with {:ok, left, tokens} <- parse_not(tokens, opts) do
      parse_and_tail(left, tokens, opts)
    end
  end

  defp parse_and_tail(left, [:and | tokens], opts) do
    with {:ok, right, tokens} <- parse_not(tokens, opts) do
      parse_and_tail({:and, left, right}, tokens, opts)
    end
  end

  defp parse_and_tail(left, tokens, _opts), do: {:ok, left, tokens}

  defp parse_not([:not | tokens], opts) do
    with {:ok, expr, tokens} <- parse_not(tokens, opts) do
      {:ok, {:not, expr}, tokens}
    end
  end

  defp parse_not(tokens, opts), do: parse_primary(tokens, opts)

  defp parse_primary([:lparen | tokens], opts) do
    with {:ok, expr, [:rparen | tokens]} <- parse_or(tokens, opts) do
      {:ok, expr, tokens}
    else
      {:ok, _expr, _tokens} ->
        parse_error("missing closing parenthesis", nil)

      {:error, _error} = error ->
        error
    end
  end

  defp parse_primary([{:boolean, value} | tokens], _opts), do: {:ok, value, tokens}
  defp parse_primary(tokens, opts), do: parse_comparison(tokens, opts)

  defp parse_comparison(tokens, opts) do
    with {:ok, path, tokens} <- parse_path(tokens, opts),
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

  defp parse_path([token | tokens], opts) do
    with {:ok, root} <- segment_value(token),
         {:ok, root} <- normalize_root(root, opts),
         {:ok, segments, tokens} <- parse_path_segments(root, tokens),
         true <- valid_path?(root, segments) do
      {:ok, [root | segments], tokens}
    else
      false -> parse_error("invalid condition path", token)
      {:error, _reason} = error -> error
    end
  end

  defp parse_path(_tokens, _opts), do: parse_error("expected condition path", nil)

  defp normalize_root(root, opts) do
    cond do
      root in ["input", "shots"] ->
        {:ok, root}

      root == "steps" and Keyword.get(opts, :authoring_aliases?, false) ->
        {:ok, "shots"}

      true ->
        parse_error("invalid condition path", {:identifier, root})
    end
  end

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

  defp collect_shot_references({:not, ast}), do: collect_shot_references(ast)

  defp collect_shot_references({:and, left, right}),
    do: collect_shot_references(left) ++ collect_shot_references(right)

  defp collect_shot_references({:or, left, right}),
    do: collect_shot_references(left) ++ collect_shot_references(right)

  defp collect_shot_references({:compare, ["shots", shot_id | _segments], _op, _literal}),
    do: [shot_id]

  defp collect_shot_references({:compare, _path, _op, _literal}), do: []
  defp collect_shot_references(_ast), do: []

  defp rewrite_shot_ast({:not, ast}, old_id, new_id),
    do: {:not, rewrite_shot_ast(ast, old_id, new_id)}

  defp rewrite_shot_ast({:and, left, right}, old_id, new_id) do
    {:and, rewrite_shot_ast(left, old_id, new_id), rewrite_shot_ast(right, old_id, new_id)}
  end

  defp rewrite_shot_ast({:or, left, right}, old_id, new_id) do
    {:or, rewrite_shot_ast(left, old_id, new_id), rewrite_shot_ast(right, old_id, new_id)}
  end

  defp rewrite_shot_ast({:compare, ["shots", old_id | segments], op, literal}, old_id, new_id) do
    {:compare, ["shots", new_id | segments], op, literal}
  end

  defp rewrite_shot_ast(ast, _old_id, _new_id), do: ast

  defp render(true, _parent_precedence), do: "true"
  defp render(false, _parent_precedence), do: "false"

  defp render({:or, left, right}, parent_precedence) do
    render_binary(:or, left, right, 1, parent_precedence)
  end

  defp render({:and, left, right}, parent_precedence) do
    render_binary(:and, left, right, 2, parent_precedence)
  end

  defp render({:not, ast}, parent_precedence) do
    rendered = "not " <> render(ast, 3)
    maybe_parenthesize(rendered, 3, parent_precedence)
  end

  defp render({:compare, path, :exists, _literal}, _parent_precedence) do
    render_path(path) <> " exists"
  end

  defp render({:compare, path, op, literal}, _parent_precedence) do
    render_path(path) <> " " <> render_operator(op) <> " " <> render_literal(literal)
  end

  defp render_binary(op, left, right, precedence, parent_precedence) do
    rendered =
      render(left, precedence) <> " " <> Atom.to_string(op) <> " " <> render(right, precedence)

    maybe_parenthesize(rendered, precedence, parent_precedence)
  end

  defp maybe_parenthesize(rendered, precedence, parent_precedence) do
    if precedence < parent_precedence, do: "(" <> rendered <> ")", else: rendered
  end

  defp render_path(path), do: Enum.join(path, ".")

  defp render_operator(:eq), do: "=="
  defp render_operator(:neq), do: "!="
  defp render_operator(:gt), do: ">"
  defp render_operator(:gte), do: ">="
  defp render_operator(:lt), do: "<"
  defp render_operator(:lte), do: "<="
  defp render_operator(:in), do: "in"

  defp render_literal(value) when is_binary(value), do: Jason.encode!(value)
  defp render_literal(value) when is_number(value), do: to_string(value)
  defp render_literal(value) when is_boolean(value), do: Atom.to_string(value)
  defp render_literal(nil), do: "null"

  defp render_literal(values) when is_list(values),
    do: "[" <> (values |> Enum.map(&render_literal/1) |> Enum.join(", ")) <> "]"

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
