Code.require_file("../test_helper.exs", __DIR__)

defmodule ExUnit.ManifestTest do
  use ExUnit.Case, async: false

  import ExUnit.Manifest
  import ExUnit.TestHelpers, only: [tmp_path: 0, in_tmp: 2]

  describe "to_last_run_status_index/1" do
    test "converts the manifest to an index of statuses keyed by test id" do
      manifest =
        manifest([
          {{TestMod1, :test_1}, entry(last_run_status: :failed, file: "file_1")},
          {{TestMod1, :test_2}, entry(last_run_status: :passed, file: "file_1")}
        ])

      assert to_last_run_status_index(manifest) == %{
               {TestMod1, :test_1} => :failed,
               {TestMod1, :test_2} => :passed
             }
    end
  end

  describe "get_files_with_failures/1" do
    test "returns a set of the files that have failures" do
      manifest =
        manifest([
          {{TestMod1, :test_1}, entry(last_run_status: :failed, file: "file_1")},
          {{TestMod1, :test_2}, entry(last_run_status: :failed, file: "file_1")},
          {{TestMod2, :test_1}, entry(last_run_status: :passed, file: "file_2")},
          {{TestMod3, :test_1}, entry(last_run_status: :failed, file: "file_3")}
        ])

      assert get_files_with_failures(manifest) == MapSet.new(["file_1", "file_3"])
    end
  end

  describe "add_test/2" do
    test "ignores tests that have an invalid :file value (which can happen when returning a `:file` option from `setup`))" do
      test = %ExUnit.Test{state: nil, tags: %{file: :not_a_file}}

      assert add_test(new(), test) == new()
    end

    test "ignores skipped tests since we know nothing about their pass/fail status" do
      test = %ExUnit.Test{state: {:skipped, "reason"}}

      assert add_test(new(), test) == new()
    end

    test "ignores excluded tests since we know nothing about their pass/fail status" do
      test = %ExUnit.Test{state: {:excluded, "reason"}}

      assert add_test(new(), test) == new()
    end

    test "stores passed tests, keyed by module and name" do
      test = %ExUnit.Test{
        state: nil,
        module: SomeMod,
        name: :t1,
        tags: %{file: "file"}
      }

      assert add_test(new(), test) ==
               manifest([
                 {{SomeMod, :t1}, entry(last_run_status: :passed, file: "file")}
               ])
    end

    test "stores failed tests, keyed by module and name" do
      test = %ExUnit.Test{
        state: {:failed, []},
        module: SomeMod,
        name: :t1,
        tags: %{file: "file"}
      }

      assert add_test(new(), test) ==
               manifest([
                 {{SomeMod, :t1}, entry(last_run_status: :failed, file: "file")}
               ])
    end

    test "stores invalid tests as failed, keyed by module and name" do
      test = %ExUnit.Test{
        state: {:invalid, SomeMod},
        module: SomeMod,
        name: :t1,
        tags: %{file: "file"}
      }

      assert add_test(new(), test) ==
               manifest([
                 {{SomeMod, :t1}, entry(last_run_status: :failed, file: "file")}
               ])
    end
  end

  @manifest_path "example-manifest"
  @file_name Path.join(@manifest_path, ".ex_unit_results.elixir")

  describe "write!/2 and read/1" do
    test "can roundtrip a manifest", context do
      manifest = non_blank_manifest()

      in_tmp(context.test, fn ->
        assert write!(manifest) == :ok
        assert read(@manifest_path) == manifest
      end)
    end

    test "returns a blank manifest when loading a file that does not exit" do
      path = tmp_path() <> "missing.manifest"
      refute File.exists?(path)
      assert read(path) == new(path)
    end

    test "returns a blank manifest when the file is corrupted", context do
      manifest = non_blank_manifest()

      in_tmp(context.test, fn ->
        assert write!(manifest) == :ok
        corrupted = "corrupted" <> File.read!(@file_name)
        File.write!(@file_name, corrupted)
        assert read(@manifest_path) == new()
      end)
    end

    test "returns a blank manifest when the file was saved at a prior version", context do
      %{entries: entries} = manifest = non_blank_manifest()

      in_tmp(context.test, fn ->
        assert write!(manifest) == :ok
        assert {vsn, ^entries} = @file_name |> File.read!() |> :erlang.binary_to_term()
        File.write!(@file_name, :erlang.term_to_binary({vsn + 1, entries}))

        assert read(@manifest_path) == new()
      end)
    end
  end

  defp non_blank_manifest do
    test = %ExUnit.Test{
      state: nil,
      module: SomeMod,
      name: :t1,
      tags: %{file: "file"}
    }

    add_test(new(), test)
  end

  describe "merge/2" do
    @existing_file_1 __ENV__.file
    @existing_file_2 Path.join(__DIR__, "../test_helper.exs")
    @missing_file "missing_file_test.exs"

    defmodule TestMod1 do
      def test_1(_), do: :ok
      def test_2(_), do: :ok
    end

    defmodule TestMod2 do
      def test_1(_), do: :ok
      def test_2(_), do: :ok
    end

    defp merge_and_sort(old, new) do
      old |> ExUnit.Manifest.merge(new) |> Map.update!(:entries, &Enum.sort/1)
    end

    test "returns the new manifest when the old manifest is blank" do
      new_manifest = manifest([{{TestMod1, :test_1}, entry()}])

      assert merge_and_sort(new(), new_manifest) == new_manifest
    end

    test "replaces old entries with their updated status" do
      old_manifest =
        manifest([
          {{TestMod1, :test_1}, entry(last_run_status: :failed, file: @existing_file_1)},
          {{TestMod1, :test_2}, entry(last_run_status: :passed, file: @existing_file_1)}
        ])

      new_manifest =
        manifest([
          {{TestMod1, :test_1}, entry(last_run_status: :passed, file: @existing_file_1)},
          {{TestMod1, :test_2}, entry(last_run_status: :failed, file: @existing_file_1)}
        ])

      assert merge_and_sort(old_manifest, new_manifest) == new_manifest
    end

    test "keeps old entries for test modules in existing files that were not part of this run" do
      old_manifest =
        manifest([
          {{UnknownMod1, :test_1}, entry(last_run_status: :failed, file: @existing_file_1)},
          {{UnknownMod1, :test_2}, entry(last_run_status: :passed, file: @existing_file_1)}
        ])

      new_manifest =
        manifest([
          {{TestMod2, :test_1}, entry(last_run_status: :passed, file: @existing_file_2)},
          {{TestMod2, :test_2}, entry(last_run_status: :failed, file: @existing_file_2)}
        ])

      assert merge_and_sort(old_manifest, new_manifest) ==
               manifest([
                 {{TestMod2, :test_1}, entry(last_run_status: :passed, file: @existing_file_2)},
                 {{TestMod2, :test_2}, entry(last_run_status: :failed, file: @existing_file_2)},
                 {{UnknownMod1, :test_1}, entry(last_run_status: :failed, file: @existing_file_1)},
                 {{UnknownMod1, :test_2}, entry(last_run_status: :passed, file: @existing_file_1)}
               ])
    end

    test "keeps old entries for tests that were loaded but skipped as part of this run" do
      old_manifest =
        manifest([
          {{TestMod1, :test_1}, entry(last_run_status: :failed, file: @existing_file_1)},
          {{TestMod1, :test_2}, entry(last_run_status: :passed, file: @existing_file_1)}
        ])

      new_manifest =
        manifest([
          {{TestMod1, :test_1}, entry(last_run_status: :passed, file: @existing_file_1)}
        ])

      assert merge_and_sort(old_manifest, new_manifest) ==
               manifest([
                 {{TestMod1, :test_1}, entry(last_run_status: :passed, file: @existing_file_1)},
                 {{TestMod1, :test_2}, entry(last_run_status: :passed, file: @existing_file_1)}
               ])
    end

    test "drops old entries from test files that no longer exist" do
      old_manifest =
        manifest([
          {{TestMod2, :test_1}, entry(last_run_status: :failed, file: @missing_file)},
          {{TestMod2, :test_2}, entry(last_run_status: :passed, file: @missing_file)}
        ])

      new_manifest =
        manifest([
          {{TestMod1, :test_1}, entry(last_run_status: :passed, file: @existing_file_1)},
          {{TestMod1, :test_2}, entry(last_run_status: :failed, file: @existing_file_1)}
        ])

      assert merge_and_sort(old_manifest, new_manifest) ==
               manifest([
                 {{TestMod1, :test_1}, entry(last_run_status: :passed, file: @existing_file_1)},
                 {{TestMod1, :test_2}, entry(last_run_status: :failed, file: @existing_file_1)}
               ])
    end

    test "drops old entries for deleted tests from loaded modules" do
      old_manifest =
        manifest([
          {{TestMod2, :missing_1}, entry(last_run_status: :failed, file: @existing_file_1)},
          {{TestMod2, :missing_2}, entry(last_run_status: :passed, file: @existing_file_2)}
        ])

      new_manifest =
        manifest([
          {{TestMod1, :test_1}, entry(last_run_status: :passed, file: @existing_file_1)},
          {{TestMod1, :test_2}, entry(last_run_status: :failed, file: @existing_file_1)}
        ])

      assert merge_and_sort(old_manifest, new_manifest) ==
               manifest([
                 {{TestMod1, :test_1}, entry(last_run_status: :passed, file: @existing_file_1)},
                 {{TestMod1, :test_2}, entry(last_run_status: :failed, file: @existing_file_1)}
               ])
    end
  end

  defp new do
    new(@manifest_path)
  end

  defp manifest(entries) do
    %ExUnit.Manifest{entries: entries, dir: @manifest_path}
  end
end
