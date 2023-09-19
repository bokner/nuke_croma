defmodule NukeCroma do
  use Croma
  require Logger

  alias Sourceror.Zipper, as: Z

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
        case collect_multiheads(node) do
          nil ->
            {node, acc}

          {_func, 0} ->
            {node, acc}

          {%Z{node: {_node, _meta, signature_children}} = signature, heads} ->
            func_name = hd(signature_children) |> elem(0)

            case heads_to_clauses(func_name, heads) do
              [] ->
                {node, acc}

              clauses ->
                spec_node = create_spec(signature)

                {
                  Enum.reduce(clauses, Z.insert_left(node, spec_node), fn clause, acc ->
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

  defp collect_multiheads(%Z{node: {func_kind, _node_meta, _children}} = zipper)
       when func_kind in [:defun, :defunp] do
    # Lazy solution - don't want to drag this through traversal process
    Process.put(:func_kind, (func_kind == :defun && :def) || :defp)

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

  defp collect_multiheads(_zipper) do
    nil
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

  def create_spec(signature) do
    ("@spec " <>
       patch_spec(signature))
    |> Sourceror.parse_string()
    |> then(fn
      {:ok, ast} ->
        ast
        |> Z.zip()
        |> Z.root()

      {:error, error} ->
        {:error, error}
    end)
  end

  def patch_spec(signature) do
    %Z{node: {_signature_node, _meta, signature_children}} = signature |> Z.down()

    patches =
      Enum.map(signature_children, fn c -> Sourceror.to_string(c) |> patch_spec_argument() end)

    original_source = zipper_to_source(signature)

    Enum.reduce(patches, original_source, fn {orig, patched}, acc ->
      String.replace(acc, orig, patched)
    end)
  end

  defp patch_spec_argument(arg_string) do
    delimiter = " :: "
    [arg_name, arg_spec] = String.split(arg_string, delimiter)

    patched_arg_name =
      if String.match?(arg_name, ~r{^[a-z]}) do
        arg_name
      else
        "_"
      end

    {arg_string, patched_arg_name <> delimiter <> arg_spec}
  end

  def heads_to_clauses(func_name, heads) do
    Enum.reduce_while(heads, [], fn head, acc ->
      case head_to_clause(func_name, head) do
        {:error, _error} -> {:halt, []}
        clause -> {:cont, [clause | acc]}
      end
    end)
    |> Enum.reverse()
  end

  def head_to_clause(func_name, head) do
    match = Z.down(head)
    action = Z.right(match)
    func_kind = Process.get(:func_kind)
    {func_args, guard} = parse_match(match)

    """
    #{func_kind} #{func_name}(#{func_args}) #{guard} do
      #{zipper_to_source(action)}
    end
    """
    |> Sourceror.parse_string()
    |> then(fn
      {:ok, ast} ->
        ast
        |> Z.zip()
        |> Z.root()

      {:error, error} ->
        Logger.error("Head-to-clause error (#{inspect(func_name)}): #{inspect(error)}")
        {:error, error}
    end)
  end

  def zipper_to_source(zipper) do
    zipper
    |> Z.node()
    |> Sourceror.to_string()
  end

  defp parse_match(match) do
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
          |> Enum.map(fn arg -> Sourceror.to_string(arg) end)
          |> Enum.join(", "),
          "when " <> Sourceror.to_string(guard)
        }

      %Z{} = _z ->
        {match
         |> Z.node()
         |> Sourceror.to_string()
         |> clean_source(), ""}
    end
  end

  def replace_croma(source) do
    source
    |> String.split(~r{defun |defunp |do\n}, include_captures: true)
    |> Enum.reduce({"", nil, false, nil}, fn chunk,
                                             {buffer, defun?, in_croma, signature} = _acc ->
      case chunk do
        "defun " ->
          {buffer, true, true, nil}

        "defunp " ->
          {buffer, false, true, nil}

        "do\n" when in_croma ->
          {buffer <> complete_croma_call(defun?, signature), nil, false, nil}

        s when in_croma ->
          {buffer, defun?, true, s}

        outside_croma ->
          {buffer <> outside_croma, nil, false, nil}
      end
    end)
    |> elem(0)
  end

  defp complete_croma_call(defun?, croma_signature) do
    "@spec " <>
      croma_signature <>
      "\n" <> ((defun? && "def ") || "defp ") <> func_signature(croma_signature)
  end

  def func_signature(croma_signature) do
    [func_name | croma_chunks] =
      String.split(croma_signature, ~r{([^\w\?\!\%])+}, include_captures: true)

    args =
      Enum.reduce(croma_chunks, {[], nil}, fn
        " :: ", {buffer, prev} -> {[prev | buffer], nil}
        chunk, {buffer, _prev} -> {buffer, chunk}
      end)
      |> elem(0)
      |> Enum.reverse()

    func_name <> "(" <> Enum.join(args, ", ") <> ")" <> " do\n"
  end

  defp clean_source(source) do
    source
    |> String.replace_leading("[", "")
    |> String.replace_trailing("]", "")
  end
end
