defmodule ExUnit.Manifest do
  @moduledoc false

  @type test_id :: {module, name :: atom}
  @opaque t :: [{test_id, Path.t()}]

  @manifest_vsn 1

  @spec new() :: t
  def new do
    []
  end

  @spec files_with_failures(t) :: MapSet.t(Path.t())
  def files_with_failures(manifest) do
    for({_, file} <- manifest, do: file, uniq: true)
    |> MapSet.new()
  end

  @spec failed_test_ids(t) :: MapSet.t(test_id)
  def failed_test_ids(manifest) do
    for({test_id, _} <- manifest, do: test_id)
    |> MapSet.new()
  end

  @spec add_test(t, ExUnit.Test.t()) :: t
  def add_test(manifest, %ExUnit.Test{tags: %{file: file}})
      when not is_binary(file),
      do: manifest

  def add_test(manifest, %ExUnit.Test{state: {ignored_state, _}})
      when ignored_state in [:skipped, :excluded],
      do: manifest

  def add_test(manifest, %ExUnit.Test{state: nil}), do: manifest

  def add_test(manifest, %ExUnit.Test{state: {failed_state, _}} = test)
      when failed_state in [:failed, :invalid] do
    [{{test.module, test.name}, test.tags.file} | manifest]
  end

  @spec write!(t, Path.t()) :: :ok
  def write!(manifest, file) when is_binary(file) do
    binary = :erlang.term_to_binary({@manifest_vsn, manifest})
    Path.dirname(file) |> File.mkdir_p!()
    File.write!(file, binary)
  end

  @spec read(Path.t()) :: t
  def read(file) when is_binary(file) do
    with {:ok, binary} <- File.read(file),
         {:ok, {@manifest_vsn, manifest}} when is_list(manifest) <- safe_binary_to_term(binary) do
      manifest
    else
      _ -> new()
    end
  end

  defp safe_binary_to_term(binary) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    ArgumentError ->
      :error
  end

  # Responsible for smartly merging an old and new manifest, using the following rules:
  #
  #   1. Entries in the new manifest are accepted as-is.
  #   2. Entries in the old manifest that are not in the new manifest are kept
  #      if the identified test either *definitely* exists or *might* exist.
  #
  # More specifically, old manifest entries that satisfy either of these
  # criteria are deleted:
  #
  #   1. The file the test came from no longer exists.
  #   2. The test no longer exists, as indicated by the module no longer
  #      exporting the test function. Note that we can only check this for
  #      test modules that have been loaded.
  #
  @spec merge(t, t) :: t
  def merge(old_manifest, new_manifest) do
    prune_and_merge(old_manifest, Map.new(new_manifest), %{}, new_manifest)
  end

  defp prune_and_merge([], _, _, acc), do: acc

  defp prune_and_merge([head | tail] = all, new_manifest, file_existence, acc) do
    {{mod, name} = key, file} = head
    file_exists = Map.fetch(file_existence, file)

    cond do
      Map.has_key?(new_manifest, key) ->
        # If the new manifest has this entry, we will keep that.
        prune_and_merge(tail, new_manifest, file_existence, acc)

      file_exists == :error ->
        # This is the first time we've looked up the existence of the file.
        # Cache the result and try again.
        file_existence = Map.put(file_existence, file, File.regular?(file))
        prune_and_merge(all, new_manifest, file_existence, acc)

      file_exists == {:ok, false} ->
        # The file does not exist, so we should prune the test.
        prune_and_merge(tail, new_manifest, file_existence, acc)

      :code.is_loaded(mod) != false and not function_exported?(mod, name, 1) ->
        # The test module has been loaded, but the test no longer exists, so prune it.
        prune_and_merge(tail, new_manifest, file_existence, acc)

      true ->
        # The file exists, but the test module was not loaded or the function is exported.
        prune_and_merge(tail, new_manifest, file_existence, [head | acc])
    end
  end
end
