defmodule NukeCroma do
  use Croma
  require Logger

  alias Sourceror.Zipper, as: Z

  @moduledoc """
  Documentation for `NukeCroma`.
  """
  def replace_croma_ast(source) do
    Sourceror.Zipper.Inspect.default_inspect_as(:as_code)

    {zipper, head_counts} =
      source
      |> Sourceror.parse_string!()
      |> Z.zip()
      |> Z.traverse([], fn node, acc ->
        case collect_multiheads(node) do
          nil -> {node, acc}
          {func, 0} -> {node, acc}
          res -> {node, [res | acc]}
        end
      end)
  end

  defp collect_multiheads(%Z{node: {func_node, _node_meta, _children}} = zipper)
       when func_node in [:defun, :defunp] do
    zipper
    |> Z.down()
    |> tap(fn z -> Logger.debug("Signature #{inspect(z)}") end)
    |> then(fn %Z{node: {:"::", _meta, signature_children}} = signature ->
      signature
      |> Z.right()
      |> Z.down()
      |> Z.next()
      |> Z.right()
      |> then(fn body ->
          count_heads(body)
          |> tap(fn count ->
            count > 0 && Logger.error(
          "#{inspect(count)} head(s) found in #{inspect(hd(signature_children) |> elem(0))}\n"
          <> "Body: #{inspect body}") end)
          |> then(fn count -> {hd(signature_children) |> elem(0), count} end)
          end)
          _node -> {nil, 0}
      end)
  end

  defp collect_multiheads(zipper) do
    nil
  end

  defp count_heads(body_zipper) do
    body_zipper
    |> Z.leftmost()
    |> Z.right()
    |> Z.down()
    |> count_heads(0)

  end

  defp count_heads(nil, count) do
    count
  end

  defp count_heads(%Z{node: {:->, _meta, children}} = sibling, count) do
    count_heads(Z.right(sibling), count + 1)
  end

  defp count_heads(sibling, count) do
    0
  end




  defp count_heads_traverse(zipper) do
    Logger.debug("Leftmost: #{inspect Z.leftmost(zipper) |> Z.right() |> Z.down()}")
    {_, count} =
      Z.traverse(zipper, 0, fn
        %Z{node: {:->, _meta, children}} = node, acc ->
          {node, acc + 1}

        node, acc ->
          {node, acc}
      end)

    count
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
end
