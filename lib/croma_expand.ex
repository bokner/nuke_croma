defmodule CromaExpand do
  use Croma
  alias Sourceror.Zipper, as: Z

  require Logger

  def expand(source) do
    Sourceror.Zipper.Inspect.default_inspect_as(:as_code)

    zipper =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk(fn
        {defun, _, _} = defun_ast when defun in [:defun, :defunp] ->
          Macro.expand(defun_ast, __ENV__)

        other ->
          other
      end)
      |> Z.zip()

    {new_zipper, _} =
      Z.traverse(zipper, nil, fn
        %Z{node: {:__block__, _, block_children}} = block, acc ->
          block_source = Z.node(block) |> Sourceror.to_string()

          if String.starts_with?(block_source, "@spec ") do
            Logger.debug("Found enclosed spec!")

            {Enum.reduce(flatten_block_children(block_children), block, fn def_child, block_acc ->
               Z.insert_left(block_acc, def_child)
             end)
             |> Z.remove(), acc}
          else
            {block, acc}
          end

        other, acc ->
          {other, acc}
      end)

    new_zipper
  end

  def flatten_block_children(children) do
    Enum.reduce(children, [], fn
      {:__block__, _, sub_children}, acc ->
        acc ++ sub_children

      flat, acc ->
        acc ++ [flat]
    end)
    |> then(fn res ->
      ## Remove the default header if there is only one function clause
      ## AND there is no default values in it
      if length(res) == 3 && Sourceror.to_string(Enum.at(res, 1)) |> String.contains?("\\\\") do
        res
      else
        ## The default function header is below @spec
        List.delete_at(res, 1)
      end
    end)
  end

  def insert_def(block_zipper, {:__block__, _, children} = _block) do
    Logger.debug("Block within spec")

    Enum.reduce(children, block_zipper, fn def_child, block_acc ->
      Z.insert_left(block_acc, def_child)
    end)
    |> Z.remove()
  end
end
