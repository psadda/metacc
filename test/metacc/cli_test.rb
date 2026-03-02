# frozen_string_literal: true

require "test_helper"
require "metacc/cli"

class CLITest < Minitest::Test

  # A stub that records Driver#compile and Driver#compile_and_link calls without
  # running subprocesses. Injected into CLI#run via the driver: keyword argument
  # so the full argv → Driver pipeline is exercised end-to-end.
  class StubDriver

    attr_reader :toolchain, :last_compile_call, :last_compile_and_link_call

    def initialize
      @calls = []
      @toolchain = StubToolchain.new
    end

    def compile(input_files, **options)
      @last_compile_call = { input_files:, **options }
      true
    end

    def compile_and_link(input_files, output_file, **options)
      @last_compile_and_link_call = { input_files:, output_file:, **options }
      output_file
    end

  end

  # A minimal toolchain stub that returns a fixed version banner string.
  class StubToolchain

    def version_banner
      "stub-compiler 1.0\n"
    end

  end

  # A CLI subclass that captures the path passed to run_executable instead of
  # actually invoking a subprocess.  Used to assert the --run postcondition.
  class SpyCLI < MetaCC::CLI

    attr_reader :executed_path

    private

    def system(path)
      @executed_path = path
    end

  end

  private

  # Runs the CLI with the given argv and returns the StubDriver so tests
  # can assert on what Driver#invoke received.
  def run_cli(argv)
    stub = StubDriver.new
    MetaCC::CLI.new(driver: stub).run(argv)
    stub
  end

  # Returns the last (and typically only) recorded compile call.
  def last_compile_call(stub)
    stub.last_compile_call
  end

  # Returns the last (and typically only) recorded compile_and_link call.
  def last_compile_and_link_call(stub)
    stub.last_compile_and_link_call
  end

  public

  # ---------------------------------------------------------------------------
  # Validation: missing output path
  # ---------------------------------------------------------------------------

  def test_run_missing_output_exits
    assert_raises(SystemExit) { run_cli([]) }
  end

  # ---------------------------------------------------------------------------
  # Source files and output path
  # ---------------------------------------------------------------------------

  def test_source_files_forwarded_to_driver
    call = last_compile_and_link_call(run_cli(["-o", "out", "a.c", "b.c", "c.c"]))

    assert_equal ["a.c", "b.c", "c.c"], call[:input_files]
  end

  def test_output_path_forwarded_to_driver
    call = last_compile_and_link_call(run_cli(["-o", "main.o", "main.c"]))

    assert_equal "main.o", call[:output_file]
  end

  def test_cxx_source_forwarded_to_driver
    call = last_compile_and_link_call(run_cli(["-o", "hello.o", "hello.cpp"]))

    assert_equal ["hello.cpp"], call[:input_files]
  end

  # ---------------------------------------------------------------------------
  # Include paths (-I)
  # ---------------------------------------------------------------------------

  def test_single_include_path
    call = last_compile_and_link_call(run_cli(["-I", "/usr/include", "-o", "out", "main.c"]))

    assert_equal ["/usr/include"], call[:include_paths]
  end

  def test_multiple_include_paths
    call = last_compile_and_link_call(run_cli(["-I", "/a", "-I", "/b", "-o", "out", "main.c"]))

    assert_equal ["/a", "/b"], call[:include_paths]
  end

  # ---------------------------------------------------------------------------
  # Preprocessor definitions (-D)
  # ---------------------------------------------------------------------------

  def test_single_define
    call = last_compile_and_link_call(run_cli(["-D", "FOO=1", "-o", "out", "main.c"]))

    assert_equal ["FOO=1"], call[:defs]
  end

  def test_multiple_defines
    call = last_compile_and_link_call(run_cli(["-D", "FOO", "-D", "BAR=2", "-o", "out", "main.c"]))

    assert_equal ["FOO", "BAR=2"], call[:defs]
  end

  # ---------------------------------------------------------------------------
  # Debug flag (-g / --debug)
  # ---------------------------------------------------------------------------

  def test_debug_long_flag
    call = last_compile_and_link_call(run_cli(["--debug", "-o", "out", "main.c"]))

    assert_includes call[:flags], :debug
  end

  def test_debug_short_flag
    call = last_compile_and_link_call(run_cli(["-g", "-o", "out", "main.c"]))

    assert_includes call[:flags], :debug
  end

  # ---------------------------------------------------------------------------
  # LONG_FLAGS (--lto, --asan, --ubsan, --msan, --no-rtti, --no-exceptions, --pic)
  # ---------------------------------------------------------------------------

  def test_all_long_flags_forwarded
    MetaCC::CLI::LONG_FLAGS.each do |name, sym|
      call = last_compile_and_link_call(run_cli(["--#{name}", "-o", "out", "main.c"]))

      assert_includes call[:flags], sym, "--#{name} should forward :#{sym} to driver"
    end
  end

  def test_multiple_flags_combined
    call = last_compile_and_link_call(run_cli(["--pic", "--debug", "--lto", "-o", "out", "main.c"]))

    assert_includes call[:flags], :pic
    assert_includes call[:flags], :debug
    assert_includes call[:flags], :lto
  end

  # ---------------------------------------------------------------------------
  # Output type flags (-c, --shared, --static)
  # ---------------------------------------------------------------------------

  def test_objects_short_flag
    stub = run_cli(["-c", "main.c"])

    assert last_compile_call(stub)
    refute last_compile_and_link_call(stub)
  end

  def test_shared_flag
    call = last_compile_and_link_call(run_cli(["--shared", "-o", "lib.so", "main.c"]))

    assert call
    assert_includes call[:flags], :shared
  end

  def test_static_flag
    call = last_compile_and_link_call(run_cli(["--static", "-o", "lib.a", "main.c"]))

    assert call
    assert_includes call[:flags], :static
  end

  def test_link_executable_by_default
    call = last_compile_and_link_call(run_cli(["-o", "out", "main.c"]))
    assert call
    refute_includes call[:flags], :shared
    refute_includes call[:flags], :static
  end

  # ---------------------------------------------------------------------------
  # Strip flag (-s / --strip)
  # ---------------------------------------------------------------------------

  def test_strip_long_flag
    call = last_compile_and_link_call(run_cli(["--strip", "-o", "out", "main.c"]))

    assert_includes call[:flags], :strip
  end

  def test_strip_short_flag
    call = last_compile_and_link_call(run_cli(["-s", "-o", "out", "main.c"]))

    assert_includes call[:flags], :strip
  end

  # ---------------------------------------------------------------------------
  # Linker options (-l, -L)
  # ---------------------------------------------------------------------------

  def test_lib_flag
    call = last_compile_and_link_call(run_cli(["-l", "m", "-o", "out", "main.c"]))

    assert_equal ["m"], call[:libs]
  end

  def test_libdir_flag
    call = last_compile_and_link_call(run_cli(["-L", "/usr/local/lib", "-o", "out", "main.c"]))

    assert_equal ["/usr/local/lib"], call[:link_paths]
  end

  def test_libs_and_libdirs_default_to_empty
    call = last_compile_and_link_call(run_cli(["-o", "out", "main.c"]))

    assert_equal [], call[:libs]
    assert_equal [], call[:link_paths]
  end

  def test_libs_and_link_paths_forwarded_together
    call = last_compile_and_link_call(run_cli(["--shared", "-o", "lib.so", "-l", "m", "-L", "/opt/lib", "main.c"]))

    assert_equal ["m"],        call[:libs]
    assert_equal ["/opt/lib"], call[:link_paths]
  end

  # ---------------------------------------------------------------------------
  # Toolchain-specific xflags (--xmsvc, --xgnu, --xclang, --xclangcl)
  # ---------------------------------------------------------------------------

  def test_xmsvc_single_value
    call = last_compile_and_link_call(run_cli(["--xmsvc", "Z7", "-o", "out", "main.c"]))

    assert_equal ["Z7"], call[:xflags][MetaCC::MSVC]
  end

  def test_xmsvc_multiple_values
    call = last_compile_and_link_call(run_cli(["--xmsvc", "Z7", "--xmsvc", "/EHc", "-o", "out", "main.c"]))

    assert_equal ["Z7", "/EHc"], call[:xflags][MetaCC::MSVC]
  end

  def test_xgnu_flag
    call = last_compile_and_link_call(run_cli(["--xgnu", "-march=skylake", "-o", "out", "main.c"]))

    assert_equal ["-march=skylake"], call[:xflags][MetaCC::GNU]
  end

  def test_xclang_flag
    call = last_compile_and_link_call(run_cli(["--xclang", "-fcolor-diagnostics", "-o", "out", "main.c"]))

    assert_equal ["-fcolor-diagnostics"], call[:xflags][MetaCC::Clang]
  end

  def test_xclangcl_flag
    call = last_compile_and_link_call(run_cli(["--xclangcl", "/Ot", "-o", "out", "main.c"]))

    assert_equal ["/Ot"], call[:xflags][MetaCC::ClangCL]
  end

  def test_mixed_xflags
    call = last_compile_and_link_call(run_cli(["--xmsvc", "Z7", "--xgnu", "-funroll-loops", "--xmsvc", "/EHc",
                                               "-o", "out", "main.c"]))

    assert_equal ["Z7", "/EHc"],     call[:xflags][MetaCC::MSVC]
    assert_equal ["-funroll-loops"], call[:xflags][MetaCC::GNU]
  end

  # ---------------------------------------------------------------------------
  # Combined options – verifies the full pipeline in a realistic scenario
  # ---------------------------------------------------------------------------

  def test_full_c_invocation
    stub = run_cli(["--lto", "--debug", "-c", "-I", "/inc", "-D", "FOO=1", "main.c"])
    call = last_compile_call(stub)

    assert call
    refute last_compile_and_link_call(stub)
    assert_equal ["main.c"],  call[:input_files]
    assert_nil                call[:output]
    assert_equal ["/inc"],    call[:include_paths]
    assert_equal ["FOO=1"],   call[:defs]
    assert_includes call[:flags], :lto
    assert_includes call[:flags], :debug
  end

  def test_full_cxx_invocation
    call = last_compile_and_link_call(run_cli(["--shared", "--pic",
                                               "-l", "stdc++", "-L", "/usr/lib",
                                               "-o", "libfoo.so", "foo.cpp", "bar.cpp"]))

    assert_equal ["foo.cpp", "bar.cpp"], call[:input_files]
    assert_equal "libfoo.so",            call[:output_file]
    assert_equal ["stdc++"],             call[:libs]
    assert_equal ["/usr/lib"],           call[:link_paths]
    assert_includes call[:flags], :shared
    assert_includes call[:flags], :pic
  end

  # ---------------------------------------------------------------------------
  # -o / -c mutual exclusion validation
  # ---------------------------------------------------------------------------

  def test_missing_output_path_exits
    assert_raises(SystemExit) { run_cli(["main.c"]) }
  end

  def test_output_path_with_objects_exits
    assert_raises(SystemExit) { run_cli(["-c", "-o", "main.o", "main.c"]) }
  end

  # ---------------------------------------------------------------------------
  # --run / -r flag
  # ---------------------------------------------------------------------------

  def test_run_short_flag_executes_after_compilation
    stub = StubDriver.new
    cli = SpyCLI.new(driver: stub)
    cli.run(["-r", "-o", "out", "main.c"])

    assert_equal "out", cli.executed_path
  end

  def test_run_long_flag_executes_after_compilation
    stub = StubDriver.new
    cli = SpyCLI.new(driver: stub)
    cli.run(["--run", "-o", "out", "main.c"])

    assert_equal "out", cli.executed_path
  end

  def test_run_not_triggered_without_flag
    stub = StubDriver.new
    cli = SpyCLI.new(driver: stub)
    cli.run(["-o", "out", "main.c"])

    assert_nil cli.executed_path
  end

  def test_run_with_objects_exits
    assert_raises(SystemExit) { run_cli(["-r", "-c", "main.c"]) }
  end

  def test_run_with_shared_exits
    assert_raises(SystemExit) { run_cli(["-r", "--shared", "-o", "lib.so", "main.c"]) }
  end

  def test_run_with_static_exits
    assert_raises(SystemExit) { run_cli(["-r", "--static", "-o", "lib.a", "main.c"]) }
  end

  # ---------------------------------------------------------------------------
  # --help / --version
  # ---------------------------------------------------------------------------

  def test_help_flag_exits
    assert_raises(SystemExit) { MetaCC::CLI.new(driver: StubDriver.new).run(["--help"]) }
  end

  def test_version_flag_prints_banner_and_exits
    stub = StubDriver.new
    out, = capture_io do
      assert_raises(SystemExit) { MetaCC::CLI.new(driver: stub).run(["--version"]) }
    end

    assert_includes out, stub.toolchain.version_banner
  end

end
