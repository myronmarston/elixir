defmodule ExUnit.Manifest do
  @moduledoc false

  import Record

  defrecord :entry, [:last_run_status, :file]
  defstruct entries: [], dir: nil

  @opaque entries :: [{test_id, entry}]
  @type t :: %__MODULE__{entries: entries, dir: Path.t()}
  @type status :: :passed | :failed
  @type entry :: record(:entry, last_run_status: status, file: Path.t())
  @type test_id :: {module, name :: atom}
  @type last_run_status_index :: %{test_id => status}

  @manifest_vsn 1

  @spec new(Path.t()) :: t
  def new(dir) do
    %__MODULE__{dir: dir}
  end

  @spec to_last_run_status_index(t) :: last_run_status_index
  def to_last_run_status_index(%__MODULE__{entries: entries}) do
    Map.new(entries, fn {test_id, entry(last_run_status: status)} ->
      {test_id, status}
    end)
  end

  @spec get_files_with_failures(t) :: MapSet.t(Path.t())
  def get_files_with_failures(%__MODULE__{entries: entries}) do
    entries
    |> Stream.filter(fn {_, entry(last_run_status: status)} -> status == :failed end)
    |> MapSet.new(fn {_, entry(file: file)} -> file end)
  end

  @spec add_test(t, ExUnit.Test.t()) :: t
  def add_test(manifest, %ExUnit.Test{tags: %{file: file}})
      when not is_binary(file),
      do: manifest

  def add_test(manifest, %ExUnit.Test{state: {ignored_state, _}})
      when ignored_state in [:skipped, :excluded],
      do: manifest

  def add_test(manifest, %ExUnit.Test{} = test) do
    status =
      case test.state do
        nil -> :passed
        {:failed, _} -> :failed
        {:invalid, _} -> :failed
      end

    entry = entry(last_run_status: status, file: test.tags.file)
    update_in(manifest.entries, &[{{test.module, test.name}, entry} | &1])
  end

  @file_name ".ex_unit_results.elixir"

  @spec write!(t) :: :ok
  def write!(%__MODULE__{dir: dir} = manifest) do
    binary = :erlang.term_to_binary({@manifest_vsn, manifest.entries})
    File.mkdir_p!(dir)
    dir |> Path.join(@file_name) |> File.write!(binary)
  end

  @spec read(Path.t()) :: t
  def read(dir) when is_binary(dir) do
    with {:ok, binary} <- File.read(Path.join(dir, @file_name)),
         {:ok, {@manifest_vsn, entries}} when is_list(entries) <- safe_binary_to_term(binary) do
      %__MODULE__{entries: entries, dir: dir}
    else
      _ -> new(dir)
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
  def merge(%__MODULE__{entries: old_entries}, %__MODULE__{} = new_manifest) do
    new_entries = new_manifest.entries
    merged_entries = prune_and_merge(old_entries, Map.new(new_entries), %{}, new_entries)
    put_in(new_manifest.entries, merged_entries)
  end

  defp prune_and_merge([], _, _, acc), do: acc

  defp prune_and_merge([head | tail] = all, new_manifest, file_existence, acc) do
    {{mod, name} = key, entry(file: file)} = head
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
