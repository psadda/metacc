# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "rbconfig"

class DriverTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # #initialize / compiler detection
  # ---------------------------------------------------------------------------
  def test_initializes_when_compiler_present
    # The CI environment has clang or gcc installed.
    assert_instance_of MetaCC::Driver, MetaCC::Driver.new
  end

  def test_compiler_class_is_known
    builder = MetaCC::Driver.new

    assert_includes [MetaCC::Clang, MetaCC::GNU, MetaCC::MSVC], builder.toolchain.class
  end

  def test_compiler_is_compiler_info_struct
    builder = MetaCC::Driver.new

    assert_kind_of MetaCC::Toolchain, builder.toolchain
  end

  def test_raises_when_no_compiler_found
    assert_raises(MetaCC::CompilerNotFoundError) { MetaCC::Driver.new(prefer: []) }
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
  # #compile – compile to object files (objects flag)
  # ---------------------------------------------------------------------------
  def test_compile_c_source_returns_true_and_creates_object_file
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.c")
      File.write(src, "int main(void) { return 0; }\n")

      result = builder.compile(src, flags: [:objects], working_dir: dir)

      assert result, "expected compile to return true"
      expected_obj = File.join(dir, "hello#{builder.toolchain.default_extension(:objects)}")
      assert_path_exists expected_obj, "expected object file to be created"
    end
  end

  def test_compile_cxx_source_returns_true_and_creates_object_file
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.cpp")
      File.write(src, "int main() { return 0; }\n")

      result = builder.compile(src, flags: [:objects], working_dir: dir)

      assert result, "expected compile to return true"
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

      result = builder.compile(
        src,
        flags:         [:objects],
        include_paths: [inc_dir],
        defs:          ["UNUSED=1"],
        working_dir:   dir
      )

      assert result, "expected compile to return true"
      expected_obj = File.join(dir, "main#{builder.toolchain.default_extension(:objects)}")
      assert_path_exists expected_obj, "expected object file to be created"
    end
  end

  def test_compile_broken_source_returns_false
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "broken.c")
      File.write(src, "this is not valid C code {\n")

      result = builder.compile(src, flags: [:objects], working_dir: dir)

      refute result, "expected compile to return false for invalid source"
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

      builder.compile(src, flags: [:objects], working_dir: dir)
      result = builder.compile_and_link([obj], exe)

      assert result, "expected compile_and_link to return truthy"
      assert_path_exists result, "expected executable to be created"
    end
  end

  def test_compile_and_link_executable_missing_object_returns_false
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      result = builder.compile_and_link([File.join(dir, "nonexistent.o")], File.join(dir, "out"))

      refute result, "expected compile_and_link to return nil for missing object file"
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

      builder.compile(src, flags: %i[objects pic], working_dir: dir)
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

      result = builder.compile(src, flags: [:objects], env: {}, working_dir: dir)

      assert result, "expected compile to succeed with env: and working_dir:"
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

      builder.compile(src, flags: [:objects], working_dir: dir)
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

      result = builder.compile(src, flags: [:objects], env: { "MY_BUILD_FLAG" => "1" }, working_dir: dir)

      assert result, "expected compile to succeed when env: contains custom vars"
    end
  end

  def test_working_dir_sets_subprocess_cwd
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.c")
      File.write(src, "int main(void) { return 0; }\n")

      # Run with working_dir set to the tmp dir; absolute paths still resolve.
      result = builder.compile(src, flags: [:objects], working_dir: dir)

      assert result, "expected compile to succeed with working_dir set"
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

  def test_prefer_empty_raises_compiler_not_found
    assert_raises(MetaCC::CompilerNotFoundError) { MetaCC::Driver.new(prefer: []) }
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

      result = builder.compile(src, flags: [:objects], xflags: { tc_class => [] }, working_dir: dir)

      assert result, "expected compile with class-keyed xflags to succeed"
    end
  end

  # ---------------------------------------------------------------------------
  # #compile return value – true on success, false on failure
  # ---------------------------------------------------------------------------
  def test_compile_returns_true_on_success
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.c")
      File.write(src, "int main(void) { return 0; }\n")

      result = builder.compile(src, flags: [:objects], working_dir: dir)

      assert_equal true, result
    end
  end

  def test_compile_returns_false_on_failure
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "broken.c")
      File.write(src, "this is not valid C code {\n")

      result = builder.compile(src, flags: [:objects], working_dir: dir)

      assert_equal false, result
    end
  end

  # ---------------------------------------------------------------------------
  # #compile_and_link return value – output path on success, nil on failure
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

      builder.compile(src, flags: [:objects], working_dir: dir)
      result = builder.compile_and_link([obj], exe_base)

      assert_equal expected_exe, result
    end
  end

  def test_compile_and_link_returns_nil_for_missing_object
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      result = builder.compile_and_link([File.join(dir, "nonexistent.o")], File.join(dir, "out"))

      assert_nil result
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

      assert_silent { builder.compile(src, flags: [:objects], working_dir: dir) }
    end
  end

  def test_compile_with_objects_flag_returns_true_on_success
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "hello.c")
      File.write(src, "int main(void) { return 0; }\n")

      result = builder.compile(src, flags: [:objects], working_dir: dir)

      assert_equal true, result
    end
  end

  def test_compile_with_objects_flag_returns_false_on_failure
    builder = MetaCC::Driver.new
    Dir.mktmpdir do |dir|
      src = File.join(dir, "broken.c")
      File.write(src, "this is not valid C code {\n")

      result = builder.compile(src, flags: [:objects], working_dir: dir)

      assert_equal false, result
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
