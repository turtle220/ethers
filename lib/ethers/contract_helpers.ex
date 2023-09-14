defmodule Ethers.ContractHelpers do
  @moduledoc false

  require Logger

  @spec read_abi(Keyword.t()) :: {:ok, [...]} | {:error, atom()}
  def read_abi(opts) do
    case Keyword.take(opts, [:abi, :abi_file]) do
      [{type, data}] ->
        read_abi(type, data)

      _ ->
        {:error, :bad_argument}
    end
  end

  @spec maybe_read_contract_binary(Keyword.t()) :: binary() | nil
  def maybe_read_contract_binary(opts) do
    case Keyword.take(opts, [:abi, :abi_file]) do
      [{type, data}] ->
        maybe_read_contract_binary(type, data)

      _ ->
        raise ArgumentError, "Invalid options"
    end
  end

  def document_types(types, names \\ []) do
    if length(types) <= length(names) do
      Enum.zip(types, names)
    else
      types
    end
    |> Enum.map_join("\n", fn
      {type, ""} ->
        " - `#{inspect(type)}`"

      {type, name} when is_binary(name) or is_atom(name) ->
        " - #{name}: `#{inspect(type)}`"

      type ->
        " - `#{inspect(type)}`"
    end)
  end

  def document_help_message(selectors) do
    selectors
    |> Enum.map(& &1.state_mutability)
    |> Enum.uniq()
    |> do_document_help_message()
  end

  defp do_document_help_message([state_mutability]) do
    message =
      case state_mutability do
        sm when sm in [:pure, :view] ->
          """
          This function should only be called for result and never in a transaction on its own. (Use `Ethers.call/2`)
          """

        :non_payable ->
          """
          This function can be used for a transaction or additionally called for results (Use `Ethers.send/2`).
          No amount of Ether can be sent with this function.
          """

        :payable ->
          """
          This function can be used for a transaction or additionally called for results (Use `Ethers.send/2`)."
          It also supports receiving ether from the transaction origin. 
          """
      end

    """
    #{message}

    State mutability: #{state_mutability}
    """
  end

  defp do_document_help_message(state_mutabilities) do
    """
    This function has multiple state mutabilities based on the overload that you use.

    State mutabilities: #{Enum.join(state_mutabilities, ",")}
    """
  end

  def document_parameters([%{types: []}]), do: ""

  def document_parameters(selectors) do
    parameters_docs =
      Enum.map_join(selectors, "\n\n### OR\n", &document_types(&1.types, &1.input_names))

    """
    ## Parameter Types
    #{parameters_docs}
    """
  end

  def document_returns(selectors) when is_list(selectors) do
    return_type_docs =
      selectors
      |> Enum.map(& &1.returns)
      |> Enum.uniq()
      |> Enum.map_join("\n\n### OR\n", fn returns ->
        if Enum.count(returns) > 0 do
          document_types(returns)
        else
          "This function does not return any values!"
        end
      end)

    """
    ## Return Types (when called with `Ethers.call/2`)
    #{return_type_docs}
    """
  end

  def document_state_mutability(selectors) do
    Enum.map_join(selectors, " OR ", & &1.state_mutability)
  end

  def human_signature(%ABI.FunctionSelector{
        input_names: names,
        types: types,
        function: function
      }) do
    args =
      if is_list(names) and length(types) == length(names) do
        Enum.zip(types, names)
      else
        types
      end
      |> Enum.map_join(", ", fn
        {type, name} when is_binary(name) ->
          String.trim("#{ABI.FunctionSelector.encode_type(type)} #{name}")

        type ->
          "#{ABI.FunctionSelector.encode_type(type)}"
      end)

    "#{function}(#{args})"
  end

  def human_signature(selectors) when is_list(selectors) do
    Enum.map_join(selectors, " OR ", &human_signature/1)
  end

  def get_overrides(module, has_other_arities) do
    if has_other_arities do
      # If the same function with different arities exists within the same contract,
      # then we would need to disable defaulting the overrides as this will cause
      # ambiguousness towards the compiler.
      quote context: module do
        overrides
      end
    else
      quote context: module do
        overrides \\ []
      end
    end
  end

  def generate_arguments(mod, arity, names) when is_integer(arity) do
    arity
    |> Macro.generate_arguments(mod)
    |> then(fn args ->
      if length(names) >= length(args) do
        args
        |> Enum.zip(names)
        |> Enum.map(&get_argument_name_ast/1)
      else
        args
      end
    end)
  end

  def generate_typespecs(selectors) do
    Enum.map(selectors, & &1.types)
    |> Enum.zip_with(& &1)
    |> Enum.map(fn type_group ->
      type_group
      |> Enum.map(&Ethers.Types.to_elixir_type/1)
      |> Enum.uniq()
      |> Enum.reduce(fn type, acc ->
        quote do
          unquote(type) | unquote(acc)
        end
      end)
    end)
  end

  def find_selector!(selectors, args) do
    filtered_selectors = Enum.filter(selectors, &selector_match?(&1, args))

    case filtered_selectors do
      [] ->
        signatures =
          Enum.map_join(selectors, "\n", &human_signature/1)

        raise ArgumentError, """
        No function selector matches current arguments!

        ## Arguments
        #{inspect(args)}

        ## Conflicting function signatures
        #{signatures}
        """

      [selector] ->
        {selector, strip_typed_args(args)}

      selectors ->
        signatures =
          Enum.map_join(selectors, "\n", &human_signature/1)

        raise ArgumentError, """
        Ambiguous parameters

        ## Arguments
        #{inspect(args)}

        ## Conflicting function signatures
        #{signatures}
        """
    end
  end

  defp strip_typed_args(args) do
    Enum.map(args, fn
      {:typed, _type, arg} -> arg
      arg -> arg
    end)
  end

  def selector_match?(selector, args) do
    Enum.zip(selector.types, args)
    |> Enum.all?(fn
      {type, {:typed, assigned_type, _arg}} -> assigned_type == type
      {type, arg} -> Ethers.Types.type_match?(type, arg)
    end)
  end

  def maybe_add_to_address(map, module) do
    case module.default_address() do
      nil -> map
      address when is_binary(address) -> Map.put(map, :to, address)
    end
  end

  defp read_abi(:abi, abi) when is_list(abi), do: {:ok, abi}
  defp read_abi(:abi, %{"abi" => abi}), do: read_abi(:abi, abi)

  defp read_abi(:abi, abi) when is_atom(abi) do
    read_abi(:abi_file, Path.join(:code.priv_dir(:ethers), "abi/#{abi}.json"))
  end

  defp read_abi(:abi, abi) when is_binary(abi) do
    abi = Ethers.json_module().decode!(abi)
    read_abi(:abi, abi)
  end

  defp read_abi(:abi_file, file) do
    abi = File.read!(file)
    read_abi(:abi, abi)
  end

  defp get_argument_name_ast({ast, name}) do
    get_argument_name_ast(ast, String.trim(name))
  end

  defp get_argument_name_ast(ast, "_" <> name), do: get_argument_name_ast(ast, name)
  defp get_argument_name_ast(ast, ""), do: ast

  defp get_argument_name_ast({orig, ctx, md}, name) when is_atom(orig) do
    name_atom = String.to_atom(Macro.underscore(name))
    {name_atom, ctx, md}
  end

  defp maybe_read_contract_binary(:abi, abi) when is_list(abi), do: nil
  defp maybe_read_contract_binary(:abi, %{"bin" => bin}) when is_binary(bin), do: bin
  defp maybe_read_contract_binary(:abi, map) when is_map(map), do: nil
  defp maybe_read_contract_binary(:abi, abi) when is_atom(abi), do: nil

  defp maybe_read_contract_binary(:abi, abi) when is_binary(abi) do
    abi = Ethers.json_module().decode!(abi)
    maybe_read_contract_binary(:abi, abi)
  end

  defp maybe_read_contract_binary(:abi_file, file) do
    abi = File.read!(file)
    maybe_read_contract_binary(:abi, abi)
  end
end
