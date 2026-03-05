# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "rbconfig"

class DriverTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # #initialize / compiler detection
  # ---------------------------------------------------------------------------
  def test_driver_toolchain_is_toolchain
    assert_kind_of MetaCC::Toolchain, MetaCC::Driver.new.toolchain
  end

  def test_raises_when_no_compiler_found
    assert_raises(MetaCC::ToolchainNotFoundError) { MetaCC::Driver.new(prefer: []) }
  end

  # ---------------------------------------------------------------------------
  # toolchain#show_version
  # ---------------------------------------------------------------------------
  def test_toolchain_show_version_returns_non_empty_string
    driver = MetaCC::Driver.new

    version = driver.toolchain.version_banner

    assert_kind_of String, version
    refute_empty version
  end

  # ---------------------------------------------------------------------------
  # #compile – compile to object files
  # ---------------------------------------------------------------------------
  def test_compile_c_source_creates_object_file
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.c")
      File.write(src, "int main(void) { return 0; }\n")

      builder.compile(src, working_dir: dir)

      expected_obj = File.join(dir, "hello#{builder.toolchain.default_extension(:objects)}")
      assert_path_exists expected_obj, "expected object file to be created"
    end
  end

  def test_compile_cxx_source_creates_object_file
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.cpp")
      File.write(src, "int main() { return 0; }\n")

      builder.compile(src, working_dir: dir)

      expected_obj = File.join(dir, "hello#{builder.toolchain.default_extension(:objects)}")
      assert_path_exists expected_obj, "expected object file to be created"
    end
  end

  def test_compile_with_include_paths_and_defs
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      inc_dir = File.join(dir, "include")
      FileUtils.mkdir_p(inc_dir)
      File.write(File.join(inc_dir, "config.h"), "#define ANSWER 42\n")

      src = File.join(dir, "main.c")
      File.write(src, "#include <config.h>\nint main(void) { return ANSWER - ANSWER; }\n")

      builder.compile(
        src,
        include_paths: [inc_dir],
        defs:          ["UNUSED=1"],
        working_dir:   dir
      )

      expected_obj = File.join(dir, "main#{builder.toolchain.default_extension(:objects)}")
      assert_path_exists expected_obj, "expected object file to be created"
    end
  end

  def test_compile_broken_source_raises_compile_error
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "broken.c")
      File.write(src, "this is not valid C code {\n")

      assert_raises(MetaCC::CompileError) { builder.compile(src, working_dir: dir) }
    end
  end

  # ---------------------------------------------------------------------------
  # #compile_and_link – link to executable (no mode flag)
  # ---------------------------------------------------------------------------
  def test_compile_and_link_executable_creates_executable
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "main.c")
      File.write(src, "int main(void) { return 0; }\n")
      obj_ext = builder.toolchain.default_extension(:objects)
      obj = File.join(dir, "main#{obj_ext}")
      exe = File.join(dir, "main")

      builder.compile(src, working_dir: dir)
      result = builder.compile_and_link([obj], exe)

      assert result, "expected compile_and_link to return truthy"
      assert_path_exists result, "expected executable to be created"
    end
  end

  def test_compile_and_link_executable_missing_object_raises_compile_error
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      assert_raises(MetaCC::CompileError) do
        builder.compile_and_link([File.join(dir, "nonexistent.o")], File.join(dir, "out"))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #compile_and_link – shared library (shared flag)
  # ---------------------------------------------------------------------------
  def test_compile_and_link_shared_creates_shared_library
    builder = MetaCC::Driver.new
    host_os = RbConfig::CONFIG["host_os"]
    skip("shared linking not tested on Windows") if host_os.match?(/mswin|mingw|cygwin/)
    skip("MSVC shared linking not tested here") if builder.toolchain.is_a?(MetaCC::MSVC)

    Dir.mktmpdir do |dir|
      src = File.join(dir, "util.c")
      File.write(src, "int add(int a, int b) { return a + b; }\n")
      obj_ext = builder.toolchain.default_extension(:objects)
      obj = File.join(dir, "util#{obj_ext}")
      lib = File.join(dir, "libutil.so")

      builder.compile(src, flags: %i[pic], working_dir: dir)
      result = builder.compile_and_link([obj], lib, flags: [:shared])

      assert result, "expected compile_and_link to return truthy"
      assert_path_exists lib, "expected shared library to be created"
    end
  end

  # ---------------------------------------------------------------------------
  # env: and working_dir: per-invocation options
  # ---------------------------------------------------------------------------
  def test_compile_accepts_env_and_working_dir
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.c")
      File.write(src, "int main(void) { return 0; }\n")

      builder.compile(src, env: {}, working_dir: dir)

      assert_path_exists File.join(dir, "hello#{builder.toolchain.default_extension(:objects)}"),
                         "expected compile to succeed with env: and working_dir:"
    end
  end

  def test_compile_and_link_executable_accepts_env_and_working_dir
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "main.c")
      File.write(src, "int main(void) { return 0; }\n")
      obj_ext = builder.toolchain.default_extension(:objects)
      obj = File.join(dir, "main#{obj_ext}")
      exe = File.join(dir, "main")

      builder.compile(src, working_dir: dir)
      result = builder.compile_and_link([obj], exe, env: {}, working_dir: dir)

      assert result, "expected compile_and_link to succeed with env: and working_dir:"
    end
  end

  def test_env_variables_are_forwarded_to_subprocess
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      # Pass a harmless env var; compilation should still succeed.
      src = File.join(dir, "hello.c")
      File.write(src, "int main(void) { return 0; }\n")

      builder.compile(src, env: { "MY_BUILD_FLAG" => "1" }, working_dir: dir)

      assert_path_exists File.join(dir, "hello#{builder.toolchain.default_extension(:objects)}"),
                         "expected compile to succeed when env: contains custom vars"
    end
  end

  def test_working_dir_sets_subprocess_cwd
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.c")
      File.write(src, "int main(void) { return 0; }\n")

      # Run with working_dir set to the tmp dir; absolute paths still resolve.
      builder.compile(src, working_dir: dir)

      expected_obj = File.join(dir, "hello#{builder.toolchain.default_extension(:objects)}")
      assert_path_exists expected_obj, "object file should exist after compile with working_dir"
    end
  end

  # ---------------------------------------------------------------------------
  # prefer: constructor option
  # ---------------------------------------------------------------------------
  def test_prefer_selects_specified_toolchain_class
    skip("gcc not available") unless MetaCC::GNU.new.available?

    builder = MetaCC::Driver.new(prefer: [MetaCC::GNU])

    assert_instance_of MetaCC::GNU, builder.toolchain
  end

  def test_prefer_empty_raises_toolchain_not_found
    assert_raises(MetaCC::ToolchainNotFoundError) { MetaCC::Driver.new(prefer: []) }
  end

  def test_prefer_default_is_clang_gnu_msvc_order
    builder = MetaCC::Driver.new

    assert_includes [MetaCC::Clang, MetaCC::GNU, MetaCC::MSVC],
                    builder.toolchain.class
  end

  # ---------------------------------------------------------------------------
  # search_paths: constructor option
  # ---------------------------------------------------------------------------
  def test_search_paths_default_is_empty
    # Verify the driver initializes without error when search_paths is empty.
    builder = MetaCC::Driver.new(search_paths: [])

    assert_instance_of MetaCC::Driver, builder
  end

  def test_search_paths_finds_compiler_in_custom_dir
    skip("bash scripts not executable on Windows") if RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/)

    Dir.mktmpdir do |dir|
      # Create a fake gcc script in a custom directory.
      fake_gcc = File.join(dir, "gcc")
      File.write(fake_gcc, "#!/bin/sh\nexec gcc \"$@\"\n")
      File.chmod(0o755, fake_gcc)

      builder = MetaCC::Driver.new(
        prefer:       [MetaCC::GNU],
        search_paths: [dir]
      )

      assert_equal fake_gcc, builder.toolchain.c
    end
  end

  # ---------------------------------------------------------------------------
  # xflags: Class-keyed extra flags
  # ---------------------------------------------------------------------------
  def test_xflags_with_class_key_is_applied_for_active_toolchain
    builder = MetaCC::Driver.new
    tc_class = builder.toolchain.class
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.c")
      File.write(src, "int main(void) { return 0; }\n")

      builder.compile(src, xflags: { tc_class => [] }, working_dir: dir)

      assert_path_exists File.join(dir, "hello#{builder.toolchain.default_extension(:objects)}"),
                         "expected compile with class-keyed xflags to succeed"
    end
  end

  # ---------------------------------------------------------------------------
  # #compile – does not raise on success, raises CompileError on failure
  # ---------------------------------------------------------------------------
  def test_compile_does_not_raise_on_success
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.c")
      File.write(src, "int main(void) { return 0; }\n")

      builder.compile(src, working_dir: dir)

      assert_path_exists File.join(dir, "hello#{builder.toolchain.default_extension(:objects)}")
    end
  end

  def test_compile_raises_compile_error_on_failure
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "broken.c")
      File.write(src, "this is not valid C code {\n")

      assert_raises(MetaCC::CompileError) { builder.compile(src, working_dir: dir) }
    end
  end

  # ---------------------------------------------------------------------------
  # #compile_and_link return value – output path on success, raises CompileError on failure
  # ---------------------------------------------------------------------------
  def test_compile_and_link_returns_output_path_for_executable
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "main.c")
      File.write(src, "int main(void) { return 0; }\n")
      obj_ext = builder.toolchain.default_extension(:objects)
      obj = File.join(dir, "main#{obj_ext}")
      exe_ext = builder.toolchain.default_extension(:executable)
      exe_base = File.join(dir, "main")
      expected_exe = exe_ext.empty? ? exe_base : "#{exe_base}#{exe_ext}"

      builder.compile(src, working_dir: dir)
      result = builder.compile_and_link([obj], exe_base)

      assert_equal expected_exe, result
    end
  end

  def test_compile_and_link_raises_compile_error_for_missing_object
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      assert_raises(MetaCC::CompileError) do
        builder.compile_and_link([File.join(dir, "nonexistent.o")], File.join(dir, "out"))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #compile – does not raise when no output path is needed
  # ---------------------------------------------------------------------------
  def test_compile_with_objects_flag_does_not_raise
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.c")
      File.write(src, "int main(void) { return 0; }\n")

      assert_silent { builder.compile(src, working_dir: dir) }
    end
  end

  def test_compile_with_objects_flag_does_not_raise_on_success
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.c")
      File.write(src, "int main(void) { return 0; }\n")

      builder.compile(src, working_dir: dir)

      assert_path_exists File.join(dir, "hello#{builder.toolchain.default_extension(:objects)}")
    end
  end

  def test_compile_with_objects_flag_raises_compile_error_on_failure
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "broken.c")
      File.write(src, "this is not valid C code {\n")

      assert_raises(MetaCC::CompileError) { builder.compile(src, working_dir: dir) }
    end
  end

  # ---------------------------------------------------------------------------
  # #compile_and_link – default extension appended when output_path has no extension
  # ---------------------------------------------------------------------------
  def test_compile_and_link_appends_extension_when_no_extension_given
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.c")
      output_base = File.join(dir, "hello")
      File.write(src, "int main(void) { return 0; }\n")

      expected_ext  = builder.toolchain.default_extension(:executable)
      expected_path = expected_ext.empty? ? output_base : "#{output_base}#{expected_ext}"

      result = builder.compile_and_link(src, output_base)

      assert_equal expected_path, result
      assert_path_exists expected_path
    end
  end

  def test_compile_and_link_does_not_modify_output_path_that_already_has_extension
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.c")
      exe = File.join(dir, "hello.exe")
      File.write(src, "int main(void) { return 0; }\n")

      result = builder.compile_and_link(src, exe)

      assert_equal exe, result
    end
  end

end

class DriverFlagTranslationTest < Minitest::Test

  # A Driver subclass that captures the compiler command produced by
  # translate_flags without invoking a real subprocess.  The real
  # auto-detected toolchain is used so flag → string translation is accurate.
  class SpyDriver < MetaCC::Driver

    attr_reader :last_cmd

    private

    def run_command(cmd, **) = @last_cmd = cmd

  end

  def driver
    SpyDriver.new
  end

  # ---------------------------------------------------------------------------
  # Flag category constants
  # ---------------------------------------------------------------------------

  def test_optimization_flags_constant_contains_all_levels
    assert_equal Set.new(%i[o0 o1 o2 o3 os]), MetaCC::Driver::OPTIMIZATION_FLAGS
  end

  def test_language_std_flags_constant_contains_all_standards
    expected = Set.new(%i[c11 c17 c23 cxx11 cxx14 cxx17 cxx20 cxx23 cxx26])
    assert_equal expected, MetaCC::Driver::LANGUAGE_STD_FLAGS
  end

  def test_architecture_flags_constant_contains_all_targets
    expected = Set.new(%i[sse4_2 avx avx2 avx512 native])
    assert_equal expected, MetaCC::Driver::ARCHITECTURE_FLAGS
  end

  def test_dbg_sanitize_flags_constant_contains_all_sanitizers
    expected = Set.new(%i[sanitize_default sanitize_memory sanitize_thread])
    assert_equal expected, MetaCC::Driver::DBG_SANITIZE_FLAGS
  end

  # ---------------------------------------------------------------------------
  # Multiple optimization flags – last one wins
  # ---------------------------------------------------------------------------

  def test_last_optimization_flag_wins_when_multiple_given
    d = driver

    d.compile("main.c", flags: [:o3])
    cmd_with_single_flag = d.last_cmd.dup

    d.compile("main.c", flags: [:o1, :o3])
    assert_equal cmd_with_single_flag, d.last_cmd
  end

  def test_earlier_optimization_flags_are_dropped
    d = driver

    d.compile("main.c", flags: [:o0])
    cmd_with_single_flag = d.last_cmd.dup

    d.compile("main.c", flags: [:o3, :o0])
    assert_equal cmd_with_single_flag, d.last_cmd
  end

  # ---------------------------------------------------------------------------
  # Multiple language standard flags – last one wins
  # ---------------------------------------------------------------------------

  def test_last_language_std_flag_wins_when_multiple_given
    d = driver

    d.compile("main.c", flags: [:c17])
    cmd_with_single_flag = d.last_cmd.dup

    d.compile("main.c", flags: [:c11, :c17])
    assert_equal cmd_with_single_flag, d.last_cmd
  end

  def test_earlier_language_std_flags_are_dropped
    d = driver

    d.compile("main.c", flags: [:c23])
    cmd_with_single_flag = d.last_cmd.dup

    d.compile("main.c", flags: [:c11, :c17, :c23])
    assert_equal cmd_with_single_flag, d.last_cmd
  end

  # ---------------------------------------------------------------------------
  # Multiple architecture flags – last one wins
  # ---------------------------------------------------------------------------

  def test_last_architecture_flag_wins_when_multiple_given
    d = driver

    d.compile("main.c", flags: [:avx2])
    cmd_with_single_flag = d.last_cmd.dup

    d.compile("main.c", flags: [:sse4_2, :avx2])
    assert_equal cmd_with_single_flag, d.last_cmd
  end

  def test_earlier_architecture_flags_are_dropped
    d = driver

    d.compile("main.c", flags: [:avx512])
    cmd_with_single_flag = d.last_cmd.dup

    d.compile("main.c", flags: [:avx, :avx2, :avx512])
    assert_equal cmd_with_single_flag, d.last_cmd
  end

  # ---------------------------------------------------------------------------
  # Multiple sanitizer flags – last one wins
  # ---------------------------------------------------------------------------

  def test_last_sanitizer_flag_wins_when_multiple_given
    d = driver

    d.compile("main.c", flags: [:sanitize_thread])
    cmd_with_single_flag = d.last_cmd.dup

    d.compile("main.c", flags: [:sanitize_default, :sanitize_thread])
    assert_equal cmd_with_single_flag, d.last_cmd
  end

  def test_earlier_sanitizer_flags_are_dropped
    d = driver

    d.compile("main.c", flags: [:sanitize_thread])
    cmd_with_single_flag = d.last_cmd.dup

    d.compile("main.c", flags: [:sanitize_default, :sanitize_memory, :sanitize_thread])
    assert_equal cmd_with_single_flag, d.last_cmd
  end

end
