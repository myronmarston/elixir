Code.require_file("../../test_helper.exs", __DIR__)

defmodule Mix.Tasks.TestTest do
  use MixTest.Case

  import Mix.Tasks.Test, only: [ex_unit_opts: 1]

  test "ex_unit_opts/1 returns ex unit options" do
    assert ex_unit_opts_from_given(unknown: "ok", seed: 13) == [seed: 13]
  end

  test "ex_unit_opts/1 returns includes and excludes" do
    included = [include: [:focus, key: "val"]]
    assert ex_unit_opts_from_given(include: "focus", include: "key:val") == included

    excluded = [exclude: [:focus, key: "val"]]
    assert ex_unit_opts_from_given(exclude: "focus", exclude: "key:val") == excluded
  end

  test "ex_unit_opts/1 translates :only into includes and excludes" do
    assert ex_unit_opts_from_given(only: "focus") == [include: [:focus], exclude: [:test]]

    only = [include: [:focus, :special], exclude: [:test]]
    assert ex_unit_opts_from_given(only: "focus", include: "special") == only
  end

  test "ex_unit_opts/1 translates :color into list containing an enabled key/value pair" do
    assert ex_unit_opts_from_given(color: false) == [colors: [enabled: false]]
    assert ex_unit_opts_from_given(color: true) == [colors: [enabled: true]]
  end

  test "ex_unit_opts/1 translates :formatter into list of modules" do
    assert ex_unit_opts_from_given(formatter: "A.B") == [formatters: [A.B]]
  end

  test "ex_unit_opts/1 includes some default options" do
    assert ex_unit_opts([]) == [
             autorun: false,
             manifest_file: Path.join(Mix.Project.manifest_path(), ".ex_unit_results.elixir")
           ]
  end

  defp ex_unit_opts_from_given(passed) do
    passed
    |> Mix.Tasks.Test.ex_unit_opts()
    |> Keyword.drop([:manifest_file, :autorun])
  end

  test "--stale: runs all tests for first run, then none on second" do
    in_fixture "test_stale", fn ->
      assert_stale_run_output("2 tests, 0 failures")

      assert_stale_run_output("""
      No stale tests
      """)
    end
  end

  test "--stale: runs tests that depend on modified modules" do
    in_fixture "test_stale", fn ->
      assert_stale_run_output("2 tests, 0 failures")

      set_all_mtimes()
      File.touch!("lib/b.ex")

      assert_stale_run_output("1 test, 0 failures")

      set_all_mtimes()
      File.touch!("lib/a.ex")

      assert_stale_run_output("2 tests, 0 failures")
    end
  end

  test "--stale: doesn't write manifest when there are failures" do
    in_fixture "test_stale", fn ->
      assert_stale_run_output("2 tests, 0 failures")

      set_all_mtimes()

      File.write!("lib/b.ex", """
      defmodule B do
        def f, do: :error
      end
      """)

      assert_stale_run_output("1 test, 1 failure")

      assert_stale_run_output("1 test, 1 failure")
    end
  end

  test "--stale: runs tests that have changed" do
    in_fixture "test_stale", fn ->
      assert_stale_run_output("2 tests, 0 failures")

      set_all_mtimes()
      File.touch!("test/a_test_stale.exs")

      assert_stale_run_output("1 test, 0 failures")
    end
  end

  test "--stale: runs tests that have changed test_helpers" do
    in_fixture "test_stale", fn ->
      assert_stale_run_output("2 tests, 0 failures")

      set_all_mtimes()
      File.touch!("test/test_helper.exs")

      assert_stale_run_output("2 tests, 0 failures")
    end
  end

  test "--stale: runs all tests no matter what with --force" do
    in_fixture "test_stale", fn ->
      assert_stale_run_output("2 tests, 0 failures")

      assert_stale_run_output(~w[--force], "2 tests, 0 failures")
    end
  end

  test "--failed: loads only files with failures and runs just the failures" do
    in_fixture "test_only_failures", fn ->
      output = mix(["test"])

      loading_only_passing_test_msg = "loading OnlyPassingTest"

      assert output =~ loading_only_passing_test_msg
      assert output =~ "3 tests, 1 failure"
      refute output =~ "excluded"

      output = mix(["test", "--failed"])

      refute output =~ loading_only_passing_test_msg
      assert output =~ "2 tests, 1 failure, 1 excluded"
    end
  end

  test "logs test absence for a project with no test paths" do
    in_fixture "test_stale", fn ->
      File.rm_rf!("test")

      assert_run_output("There are no tests to run")
    end
  end

  test "--listen-on-stdin: runs tests after input" do
    in_fixture "test_stale", fn ->
      port = mix_port(~w[test --stale --listen-on-stdin])

      assert receive_until_match(port, "seed", []) =~ "2 tests"

      Port.command(port, "\n")

      assert receive_until_match(port, "No stale tests", []) =~ "Restarting..."
    end
  end

  test "--listen-on-stdin: does not exit on compilation failure" do
    in_fixture "test_stale", fn ->
      File.write!("lib/b.ex", """
      defmodule B do
        def f, do: error_not_a_var
      end
      """)

      port = mix_port(~w[test --listen-on-stdin])

      assert receive_until_match(port, "error", []) =~ "lib/b.ex"

      File.write!("lib/b.ex", """
      defmodule B do
        def f, do: A.f
      end
      """)

      Port.command(port, "\n")

      assert receive_until_match(port, "seed", []) =~ "2 tests"

      File.write!("test/b_test_stale.exs", """
      defmodule BTest do
        use ExUnit.Case

        test "f" do
          assert B.f() == error_not_a_var
        end
      end
      """)

      Port.command(port, "\n")

      message = "undefined function error_not_a_var"
      assert receive_until_match(port, message, []) =~ "test/b_test_stale.exs"

      File.write!("test/b_test_stale.exs", """
      defmodule BTest do
        use ExUnit.Case

        test "f" do
          assert B.f() == :ok
        end
      end
      """)

      Port.command(port, "\n")

      assert receive_until_match(port, "seed", []) =~ "2 tests"
    end
  end

  defp receive_until_match(port, expected, acc) do
    receive do
      {^port, {:data, output}} ->
        acc = [acc | output]

        if output =~ expected do
          IO.iodata_to_binary(acc)
        else
          receive_until_match(port, expected, acc)
        end
    end
  end

  defp set_all_mtimes(time \\ {{2010, 1, 1}, {0, 0, 0}}) do
    Enum.each(Path.wildcard("**", match_dot: true), &File.touch!(&1, time))
  end

  defp assert_stale_run_output(opts \\ [], expected) do
    assert_run_output(["--stale" | opts], expected)
  end

  defp assert_run_output(opts \\ [], expected) do
    assert mix(["test" | opts]) =~ expected
  end
end
