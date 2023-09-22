defmodule NukeCroma do
  use Croma
  require Logger

  alias Sourceror.Zipper, as: Z

  @spec_delimiter " :: "
  @default_value_delimiter ~S" \\ "

  @moduledoc """
  Documentation for `NukeCroma`.
  """
  def replace_multiheads(source) do
    Sourceror.Zipper.Inspect.default_inspect_as(:as_code)

    {zipper, multihead_func_count} =
      source
      |> Sourceror.parse_string!()
      |> Z.zip()
      |> Z.traverse(0, fn node, acc ->
        node = Macro.expand(node, __ENV__)

        case collect_multiheads(node) do
          nil ->
            {node, acc}

          {_func, 0} ->
            {node, acc}

          {%Z{node: {_node, _meta, signature_children}} = signature, heads} ->
            func_name = hd(signature_children) |> elem(0)

            case heads_to_clauses(func_name, heads) do
              # [] ->
              #   {node, acc}

              :error ->
                # Logger.error("Head-to-clause error in #{func_name}")
                {node, acc}

              clauses ->
                {function_arg_names, spec_node} = create_spec(signature)

                multiple_clauses? = length(clauses) > 0

                initial_node =
                  node
                  |> Z.insert_left(spec_node)
                  |> maybe_insert_default_header(func_name, function_arg_names, multiple_clauses?)

                defun_replacement =
                  if multiple_clauses? do
                    clauses
                  else
                    [upgrade_to_def(node, func_name, function_arg_names)]
                  end

                {
                  Enum.reduce(defun_replacement, initial_node, fn clause, acc ->
                    Z.insert_left(acc, clause)
                  end)
                  |> Z.remove(),
                  acc + 1
                }
            end
        end
      end)

    case multihead_func_count do
      0 ->
        {source, 0}

      count ->
        {zipper
         |> Z.root()
         |> Sourceror.to_string(), count}
    end
  end

  def collect_multiheads(%Z{node: {func_kind, _node_meta, _children}} = zipper)
      when func_kind in [:defun, :defunp] do
    # Lazy solution - don't want to drag this through traversal process
    save_func_kind(func_kind)

    zipper
    |> Z.down()
    |> then(fn
      %Z{node: {:"::", _meta, signature_children}} = signature ->
        signature
        |> Z.right()
        |> Z.down()
        |> Z.next()
        |> Z.right()
        |> then(fn body ->
          collect_fun_clauses(body)
          |> tap(fn clauses ->
            count = length(clauses)

            count > 0 &&
              Logger.error(
                "#{inspect(count)} head(s) found in #{inspect(hd(signature_children) |> elem(0))}\n"
              )
          end)
          |> then(fn count -> {signature, count} end)
        end)

      _node ->
        {nil, 0}
    end)
  end

  def collect_multiheads(_zipper) do
    nil
  end

  defp collect_fun_clauses(%Z{node: {:fn, _meta, _children}}) do
    []
  end

  defp collect_fun_clauses(body_zipper) do
    body_zipper
    |> Z.leftmost()
    |> Z.right()
    |> Z.down()
    |> collect_fun_clauses([])
  end

  defp collect_fun_clauses(nil, clauses) do
    clauses
  end

  defp collect_fun_clauses(%Z{node: {:->, _meta, _children}} = sibling, clauses) do
    collect_fun_clauses(Z.right(sibling), clauses ++ [sibling])
  end

  defp collect_fun_clauses(_sibling, _clauses) do
    []
  end

  def upgrade_to_def(%Z{node: {_fun_type, _, _children}} = node, func_name, function_arg_names) do
    func_body =
      node |> Z.down() |> Z.right() |> Z.next() |> Z.next() |> Z.right() |> zipper_to_source()

    func_args = Enum.join(function_arg_names, ", ")

    func_source =
      """
      #{get_func_kind()} #{func_name}(#{func_args}) do
        #{func_body}
      end
      """

    Sourceror.parse_string!(func_source)
  end

  defp save_func_kind(func_kind) do
    Process.put(:func_kind, (func_kind == :defun && :def) || :defp)
  end

  def get_func_kind() do
    Process.get(:func_kind)
  end

  def create_spec(signature) do
    {function_args, patched_spec} = patch_spec(signature)

    {function_args,
     ("@spec " <> patched_spec)
     |> Sourceror.parse_string()
     |> then(fn
       {:ok, ast} ->
         ast
         |> Z.zip()
         |> Z.root()

       {:error, error} ->
         {:error, error}
     end)}
  end

  def patch_spec(signature) do
    %Z{node: {_signature_node, _meta, signature_children}} = signature |> Z.down()

    patches =
      Enum.map(signature_children, fn c -> Sourceror.to_string(c) |> patch_spec_argument() end)

    original_source = zipper_to_source(signature)

    {args, updated_source} =
      Enum.reduce(patches, {[], original_source}, fn {arg_name, orig, patched},
                                                     {arg_names, acc} ->
        {[arg_name | arg_names], String.replace(acc, orig, patched)}
      end)

    {Enum.reverse(args), updated_source}
  end

  defp patch_spec_argument(original) do
    [arg_name, arg_spec] =
      case String.split(original, @spec_delimiter) do
        [arg_or_spec] -> handle_arg_or_spec(arg_or_spec)
        [arg, spec] -> [arg, spec]
      end

    {default_value, patched_specs} =
      if String.match?(arg_name, ~r{^[a-z]}) do
        arg_name <> @spec_delimiter <> arg_spec
      else
        arg_spec
      end
      |> remove_default_value()

    {arg_name <> default_value, original, patched_specs}
  end

  defp remove_default_value(spec) do
    case String.split(spec, @default_value_delimiter) do
      [s, value] -> {@default_value_delimiter <> value, s}
      [s] -> {"", s}
    end
  end

  defp maybe_insert_default_header(node, _func_name, _func_arguments, false) do
    node
  end

  defp maybe_insert_default_header(node, func_name, func_arguments, true) do
    if Enum.any?(func_arguments, fn arg -> String.contains?(arg, @default_value_delimiter) end) do
      Z.insert_left(node, make_default_header(func_name, func_arguments))
    else
      node
    end
  end

  defp make_default_header(func_name, func_arguments) do
    arg_string = Enum.join(func_arguments, ", ")
    header_str = "#{get_func_kind()} #{func_name}(#{arg_string})"
    Sourceror.parse_string!(header_str)
  end

  defp handle_arg_or_spec(arg_or_spec) do
    if String.contains?(arg_or_spec, "()") do
      ["_arg", arg_or_spec]
    else
      [arg_or_spec, "any()"]
    end
  end

  def heads_to_clauses(func_name, heads) do
    Enum.reduce_while(heads, [], fn head, acc ->
      case head_to_clause(func_name, head) do
        {:error, _error} -> {:halt, :error}
        clause -> {:cont, [clause | acc]}
      end
    end)
    |> then(fn
      :error -> :error
      clauses -> Enum.reverse(clauses)
    end)
  end

  def head_to_clause(func_name, head) do
    match = Z.down(head)
    action = Z.right(match)
    func_kind = get_func_kind()
    {func_args, guard} = parse_match(match)

    clause =
      """
      #{func_kind} #{func_name}(#{func_args}) #{guard} do
        #{zipper_to_source(action)}
      end
      """

    clause
    |> Sourceror.parse_string()
    |> then(fn
      {:ok, ast} ->
        ast
        |> Z.zip()
        |> Z.root()

      {:error, error} ->
        Logger.error("""
        Head-to-clause error (#{inspect(func_name)}): #{inspect(error)}
        """)

        {:error, error}
    end)
  end

  def zipper_to_source(zipper) do
    zipper
    |> Z.node()
    |> Sourceror.to_string()
  end

  def parse_match(match) do
    case Z.down(match) do
      # Single argument
      nil ->
        {[match], nil}

      # With guard
      %Z{node: {:when, _meta, children}} ->
        [guard | args] = Enum.reverse(children)

        {
          args
          |> Enum.reverse()
          |> Enum.map(fn arg ->
            Sourceror.to_string(arg)
          end)
          |> Enum.join(", "),
          "when " <> Sourceror.to_string(guard)
        }

      %Z{} = _z ->
        {match
         |> Z.node()
         |> Z.children()
         |> Enum.map(fn c -> Sourceror.to_string(c) end)
         |> Enum.join(", "), ""}
    end
  end
end
