defmodule ExUnit.RunnerStats do
  @moduledoc false

  use GenServer
  alias ExUnit.{Manifest, Test, TestModule}

  def stats(pid) do
    GenServer.call(pid, :stats, :infinity)
  end

  def last_run_status_index(pid) do
    GenServer.call(pid, :last_run_status_index, :infinity)
  end

  # Callbacks

  def init(opts) do
    {old_manifest, new_manifest} =
      case Keyword.fetch(opts, :manifest) do
        :error -> {nil, nil}
        {:ok, old_manifest} -> {old_manifest, Manifest.new(old_manifest.dir)}
      end

    state = %{
      total: 0,
      failures: 0,
      skipped: 0,
      excluded: 0,
      old_manifest: old_manifest,
      new_manifest: new_manifest
    }

    {:ok, state}
  end

  def handle_call(:stats, _from, state) do
    stats = Map.take(state, [:total, :failures, :skipped, :excluded])
    {:reply, stats, state}
  end

  def handle_call(:last_run_status_index, _from, %{old_manifest: nil} = state) do
    {:reply, %{}, state}
  end

  def handle_call(:last_run_status_index, _from, %{old_manifest: manifest} = state) do
    {:reply, Manifest.to_last_run_status_index(manifest), state}
  end

  def handle_cast({:test_finished, %Test{} = test}, state) do
    state =
      state
      |> Map.update!(:total, &(&1 + 1))
      |> increment_status_counter(test.state)
      |> record_test(test)

    {:noreply, state}
  end

  def handle_cast({:module_finished, %TestModule{state: {:failed, _}} = test_module}, state) do
    %{failures: failures, total: total} = state
    test_count = length(test_module.tests)
    {:noreply, %{state | failures: failures + test_count, total: total + test_count}}
  end

  def handle_cast({:suite_finished, _, _}, %{old_manifest: old_manifest} = state)
      when old_manifest != nil do
    old_manifest
    |> Manifest.merge(state.new_manifest)
    |> Manifest.write!()

    {:noreply, state}
  end

  def handle_cast(_, state) do
    {:noreply, state}
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  defp increment_status_counter(state, {:skipped, _}) do
    Map.update!(state, :skipped, &(&1 + 1))
  end

  defp increment_status_counter(state, {:excluded, _}) do
    Map.update!(state, :excluded, &(&1 + 1))
  end

  defp increment_status_counter(state, {tag, _}) when tag in [:failed, :invalid] do
    Map.update!(state, :failures, &(&1 + 1))
  end

  defp increment_status_counter(state, _), do: state

  defp record_test(%{new_manifest: nil} = state, _test), do: state

  defp record_test(state, test) do
    update_in(state.new_manifest, &Manifest.add_test(&1, test))
  end
end
