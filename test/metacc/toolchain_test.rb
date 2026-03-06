# frozen_string_literal: true

require "test_helper"
require "securerandom"
require "tmpdir"
require "fileutils"
require "metacc/toolchain"


class MsvcToolchainTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # Helper: minimal MSVC subclass that prevents real subprocess calls.
  #
  # Only command_available? is stubbed.
  # ---------------------------------------------------------------------------

  def stub_msvc_class(cl_on_path: false, &block)
    klass = Class.new(MetaCC::MSVC) do
      define_method(:command_available?) do |cmd|
        cl_on_path && cmd == "cl"
      end
    end
    klass.class_eval(&block) if block
    klass
  end

  # ---------------------------------------------------------------------------
  # Constructor postconditions: cl already on PATH
  # ---------------------------------------------------------------------------

  def test_setup_when_cl_already_available
    klass = Class.new(MetaCC::MSVC) do
      define_method(:command_available?) { |cmd| cmd == "cl" }
    end
    tc = klass.new

    assert_equal "cl", tc.c
  end

  def test_available_returns_true_when_cl_is_on_path
    klass = Class.new(MetaCC::MSVC) do
      define_method(:command_available?) { |cmd| cmd == "cl" }
    end
    tc = klass.new

    assert_predicate tc, :available?
  end

  # ---------------------------------------------------------------------------
  # Constructor postconditions: cl NOT on PATH, vswhere absent
  # ---------------------------------------------------------------------------

  def test_not_available_when_vswhere_absent
    tc = stub_msvc_class(cl_on_path: false).new

    refute_predicate tc, :available?
  end

  # ---------------------------------------------------------------------------
  # vcvarsall_command: cmd.exe command string construction
  # ---------------------------------------------------------------------------

  # Helper: minimal MSVC instance with only the pure vcvarsall_command
  # method available.  Defines its own initialize to avoid the pre-existing
  # super arity issue in MSVC#initialize.
  def msvc_for_vcvarsall_command
    Class.new(MetaCC::MSVC) do
      def command_available?(_cmd) = false
    end.new
  end

  # ---------------------------------------------------------------------------
  # Integration: full setup flow with vswhere and vcvarsall
  # ---------------------------------------------------------------------------

  def test_vcvarsall_updates_environment_from_vcvarsall_bat
    # Only run this test on windows
    skip unless MetaCC::Platform.windows?

    env_key = "METACC_TEST_#{SecureRandom.hex(8)}"
    env_value = "METACC_TEST_VALUE_#{SecureRandom.hex(8)}"

    Dir.mktmpdir do |dir|
      # Compute path to temporary vcvarsall.bat
      vcvarsall_dir = File.join(dir, "VC", "Auxiliary", "Build")
      FileUtils.mkdir_p(vcvarsall_dir)
      vcvarsall_path = File.join(vcvarsall_dir, "vcvarsall.bat")

      # Write out a batch file to that path
      File.write(vcvarsall_path, "SET #{env_key}=#{env_value}\n")

      # Compute path to temporary devenv.exe
      # (The file doesn't actually have to exist for this test)
      devenv_path = File.join(dir, "Common7", "IDE", "devenv.exe")

      begin
        # Clear out DevEnvDir temporarily (because MSVC.vcvarsall
        # short-circuits when DevEnvDir is defined)
        dev_env_dir = ENV.delete("DevEnvDir")
        MetaCC::MSVC.vcvarsall(devenv_path)

        assert_equal env_value, ENV.fetch(env_key, nil)
      ensure
        ENV.delete(env_key)
        ENV["DevEnvDir"] = dev_env_dir
      end
    end
  end

  def test_vcvarsall_skips_lines_without_equals
    # Only run this test on windows
    skip unless MetaCC::Platform.windows?

    env_key = "METACC_TEST_#{SecureRandom.hex(8)}"
    env_value = "METACC_TEST_VALUE_#{SecureRandom.hex(8)}"

    Dir.mktmpdir do |dir|
      # Compute path to temporary vcvarsall.bat
      vcvarsall_dir = File.join(dir, "VC", "Auxiliary", "Build")
      FileUtils.mkdir_p(vcvarsall_dir)
      vcvarsall_path = File.join(vcvarsall_dir, "vcvarsall.bat")

      # Write out a batch file to that path
      File.write(vcvarsall_path, "ECHO no_equals_sign\nSET #{env_key}=#{env_value}\n")

      # Compute path to temporary devenv.exe
      # (The file doesn't actually have to exist for this test)
      devenv_path = File.join(dir, "Common7", "IDE", "devenv.exe")

      begin
        # Clear out DevEnvDir temporarily (because MSVC.vcvarsall
        # short-circuits when DevEnvDir is defined)
        dev_env_dir = ENV.delete("DevEnvDir")
        MetaCC::MSVC.vcvarsall(devenv_path)

        assert_equal env_value, ENV.fetch(env_key, nil)
        refute ENV.key?("no_equals_sign")
      ensure
        ENV.delete(env_key)
        ENV["DevEnvDir"] = dev_env_dir
      end
    end
  end

end

class ClangCLToolchainTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # Helper: minimal ClangCL subclass that prevents real subprocess calls.
  # ---------------------------------------------------------------------------

  def stub_clang_cl_class(clang_cl_on_path: false, &block)
    klass = Class.new(MetaCC::ClangCL) do
      define_method(:command_available?) do |cmd|
        clang_cl_on_path && cmd == "clang-cl"
      end
    end
    klass.class_eval(&block) if block
    klass
  end

  # ---------------------------------------------------------------------------
  # Constructor postconditions
  # ---------------------------------------------------------------------------

  def test_compiler_commands_are_clang_cl
    tc = stub_clang_cl_class(clang_cl_on_path: true).new

    assert_equal "clang-cl", tc.c
  end

  def test_available_returns_true_when_clang_cl_is_on_path
    tc = stub_clang_cl_class(clang_cl_on_path: true).new

    assert_predicate tc, :available?
  end

  def test_not_available_when_clang_cl_absent
    tc = stub_clang_cl_class(clang_cl_on_path: false).new

    refute_predicate tc, :available?
  end

  # ---------------------------------------------------------------------------
  # Integration: full setup flow with vswhere and vcvarsall
  # ---------------------------------------------------------------------------

  def test_integration_setup_with_vswhere_and_vcvarsall; end

end

class GnuToolchainCommandTest < Minitest::Test

  def gnu
    Class.new(MetaCC::GNU) do
      def command_available?(_cmd) = true
    end.new
  end

  # ---------------------------------------------------------------------------
  # libs: linker flags
  # ---------------------------------------------------------------------------

  def test_libs_produce_dash_l_flags_in_link_mode
    cmds = gnu.compile_and_link_commands(["main.o"], "main",
                                         flags: [], include_dirs: [], defs: [], link_dirs: [], libs: %w[m pthread])

    assert_includes cmds.flatten, "-lm"
    assert_includes cmds.flatten, "-lpthread"
  end

  def test_libs_omitted_in_compile_only_mode
    cmd = gnu.compile_command(["main.c"], flags: ["-c"], include_dirs: [], defs: [])

    refute_includes cmd, "-lm"
  end

  # ---------------------------------------------------------------------------
  # linker_include_dirs: search path flags
  # ---------------------------------------------------------------------------

  def test_linker_include_dirs_produce_dash_L_flags_in_link_mode
    cmds = gnu.compile_and_link_commands(["main.o"], "main",
                                         flags: [], include_dirs: [], defs: [], link_dirs: ["/opt/lib", "/usr/local/lib"], libs: [])

    assert_includes cmds.flatten, "-L/opt/lib"
    assert_includes cmds.flatten, "-L/usr/local/lib"
  end

  def test_linker_include_dirs_omitted_in_compile_only_mode
    cmd = gnu.compile_command(["main.c"], flags: ["-c"], include_dirs: [], defs: [])

    refute_includes cmd, "-L/opt/lib"
  end

  # ---------------------------------------------------------------------------
  # compiler executable
  # ---------------------------------------------------------------------------

  def test_compile_command_uses_gcc
    cmd = gnu.compile_command(["main.c"], flags: ["-c"], include_dirs: [], defs: [])

    assert_equal "gcc", cmd.first
  end

  # ---------------------------------------------------------------------------
  # strip flag
  # ---------------------------------------------------------------------------

  def test_strip_flag_maps_to_wl_strip_unneeded
    assert_equal ["-Wl,--strip-unneeded"], MetaCC::GNU::GNU_FLAGS[:strip]
  end

  # ---------------------------------------------------------------------------
  # sanitizer flags
  # ---------------------------------------------------------------------------

  def test_sanitize_default_flag_is_platform_appropriate
    expected = if MetaCC::Platform.windows?
                 ["-fsanitize=undefined", "-fsanitize-undefined-trap-on-error"]
               elsif MetaCC::Platform.apple?
                 []
               else
                 ["-fsanitize=address,undefined,leak"]
               end
    assert_equal expected, MetaCC::GNU::GNU_FLAGS[:sanitize_default]
  end

  def test_sanitize_memory_flag_maps_to_fsanitize_nothing
    assert_empty MetaCC::GNU::GNU_FLAGS[:sanitize_memory]
  end

  def test_sanitize_thread_flag_is_platform_appropriate
    expected = if MetaCC::Platform.windows? || MetaCC::Platform.apple?
                 []
               else
                 ["-fsanitize=thread"]
               end
    assert_equal expected, MetaCC::GNU::GNU_FLAGS[:sanitize_thread]
  end

end

class MsvcToolchainCommandTest < Minitest::Test

  def msvc
    Class.new(MetaCC::MSVC) do
      def command_available?(_cmd) = false
    end.new
  end

  # ---------------------------------------------------------------------------
  # libs: library arguments
  # ---------------------------------------------------------------------------

  def test_libs_produce_dot_lib_in_link_mode
    cmds = msvc.compile_and_link_commands(["main.obj"], "main.exe",
                                          flags: [], include_dirs: [], defs: [], link_dirs: [], libs: %w[user32 gdi32])

    assert_includes cmds.flatten, "user32.lib"
    assert_includes cmds.flatten, "gdi32.lib"
  end

  def test_libs_omitted_in_compile_only_mode
    cmd = msvc.compile_command(["main.c"], flags: ["/c"], include_dirs: [], defs: [])

    refute_includes cmd, "user32.lib"
  end

  # ---------------------------------------------------------------------------
  # linker_include_dirs: /link /LIBPATH:
  # ---------------------------------------------------------------------------

  def test_linker_include_dirs_produce_libpath_in_link_mode
    cmd = msvc.compile_and_link_commands(["main.obj"], "main.exe",
                                         flags: [], include_dirs: [], defs: [], link_dirs: ["C:\\mylibs"], libs: [])

    assert_includes cmd.flatten, "/link"
    assert_includes cmd.flatten, "/LIBPATH:C:\\mylibs"
  end

  def test_linker_include_dirs_omitted_in_compile_only_mode
    cmd = msvc.compile_command(["main.c"], flags: ["/c"], include_dirs: [], defs: [])

    refute_includes cmd.flatten, "/link"
    refute_includes cmd.flatten, "/LIBPATH:C:\\mylibs"
  end

  def test_link_switch_absent_when_no_linker_include_dirs
    cmds = msvc.compile_and_link_commands(["main.obj"], "main.exe",
                                          flags: [], include_dirs: [], defs: [], link_dirs: [], libs: [])

    refute_includes cmds.flatten, "/link"
  end

  # ---------------------------------------------------------------------------
  # strip flag
  # ---------------------------------------------------------------------------

  def test_strip_flag_maps_to_empty_array
    assert_equal [], MetaCC::MSVC::MSVC_FLAGS[:strip]
  end

  # ---------------------------------------------------------------------------
  # sanitizer flags
  # ---------------------------------------------------------------------------

  def test_sanitize_default_flag_maps_to_fsanitize_address
    assert_equal ["/fsanitize=address"], MetaCC::MSVC::MSVC_FLAGS[:sanitize_default]
  end

  def test_sanitize_memory_flag_maps_to_empty_array
    assert_equal [], MetaCC::MSVC::MSVC_FLAGS[:sanitize_memory]
  end

  def test_sanitize_thread_flag_maps_to_empty_array
    assert_equal [], MetaCC::MSVC::MSVC_FLAGS[:sanitize_thread]
  end

end

class ToolchainLanguagesTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # Default languages: toolchains that support both C and C++
  # ---------------------------------------------------------------------------

  def test_gnu_toolchain_supports_c_and_cxx
    assert_equal %i[c cxx], MetaCC::GNU.allocate.languages
  end

  def test_clang_toolchain_supports_c_and_cxx
    assert_equal %i[c cxx], MetaCC::Clang.allocate.languages
  end

  def test_msvc_toolchain_supports_c_and_cxx
    assert_equal %i[c cxx], MetaCC::MSVC.allocate.languages
  end

  def test_clang_cl_toolchain_supports_c_and_cxx
    assert_equal %i[c cxx], MetaCC::ClangCL.allocate.languages
  end

  # ---------------------------------------------------------------------------
  # TinyCC: C only
  # ---------------------------------------------------------------------------

  def test_tinycc_toolchain_supports_c_only
    assert_equal %i[c], MetaCC::TinyCC.allocate.languages
  end

end

class TinyCCToolchainTest < Minitest::Test

  def tcc
    Class.new(MetaCC::TinyCC) do
      def command_available?(_cmd) = true
    end.new
  end

  # ---------------------------------------------------------------------------
  # Constructor postconditions
  # ---------------------------------------------------------------------------

  def test_compiler_command_is_tcc
    assert_equal "tcc", tcc.c
  end

  def test_available_returns_true_when_tcc_present
    assert_predicate tcc, :available?
  end

  def test_not_available_when_tcc_absent
    tc = Class.new(MetaCC::TinyCC) do
      def command_available?(_cmd) = false
    end.new

    refute_predicate tc, :available?
  end

  # ---------------------------------------------------------------------------
  # compile_command / compile_and_link_commands: structure
  # ---------------------------------------------------------------------------

  def test_compile_command_starts_with_tcc
    cmd = tcc.compile_command(["main.c"], flags: [], include_dirs: [], defs: [])

    assert_equal "tcc", cmd.first
  end

  def test_compile_and_link_command_includes_output_flag
    cmds = tcc.compile_and_link_commands(["main.c"], "main",
                                         flags: [], include_dirs: [], defs: [], link_dirs: [], libs: []).flatten

    assert_includes cmds, "-o"
    assert_equal "main", cmds[cmds.index("-o") + 1]
  end

  def test_include_dirs_produce_dash_I_flags
    cmd = tcc.compile_command(["main.c"],
                              flags: [], include_dirs: ["/usr/include", "/opt/include"], defs: [])

    assert_includes cmd, "-I/usr/include"
    assert_includes cmd, "-I/opt/include"
  end

  def test_definitions_produce_dash_D_flags
    cmd = tcc.compile_command(["main.c"],
                              flags: [], include_dirs: [], defs: %w[FOO BAR=1])

    assert_includes cmd, "-DFOO"
    assert_includes cmd, "-DBAR=1"
  end

  def test_libs_produce_dash_l_flags_in_link_mode
    cmds = tcc.compile_and_link_commands(["main.o"], "main",
                                         flags: [], include_dirs: [], defs: [], link_dirs: [], libs: %w[m pthread])

    assert_includes cmds.flatten, "-lm"
    assert_includes cmds.flatten, "-lpthread"
  end

  def test_libs_omitted_in_compile_only_mode
    cmd = tcc.compile_command(["main.c"], flags: ["-c"], include_dirs: [], defs: [])

    refute_includes cmd, "-lm"
  end

  def test_linker_include_dirs_produce_dash_L_flags_in_link_mode
    cmds = tcc.compile_and_link_commands(["main.o"], "main",
                                         flags: [], include_dirs: [], defs: [], link_dirs: ["/opt/lib"], libs: [])

    assert_includes cmds.flatten, "-L/opt/lib"
  end

  def test_linker_include_dirs_omitted_in_compile_only_mode
    cmd = tcc.compile_command(["main.c"], flags: ["-c"], include_dirs: [], defs: [])

    refute_includes cmd, "-L/opt/lib"
  end

end

class ToolchainDefaultExtensionTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # GNU / Clang: OS-based extensions
  # ---------------------------------------------------------------------------

  def gnu
    Class.new(MetaCC::GNU) do
      def command_available?(_cmd) = true
    end.new
  end

  def test_gnu_objects_extension
    assert_equal ".o", gnu.default_extension(:objects)
  end

  def test_gnu_static_extension
    assert_equal ".a", gnu.default_extension(:static)
  end

  def test_gnu_shared_extension_on_current_os
    expected = MetaCC::Platform.shared_library_ext

    assert_equal expected, gnu.default_extension(:shared)
  end

  def test_gnu_executable_extension_on_current_os
    expected = MetaCC::Platform.executable_ext

    assert_equal expected, gnu.default_extension(:executable)
  end

  # ---------------------------------------------------------------------------
  # MSVC: always Windows extensions regardless of host OS
  # ---------------------------------------------------------------------------

  def msvc
    Class.new(MetaCC::MSVC) do
      def command_available?(_cmd) = false
    end.new
  end

  def test_msvc_objects_extension
    assert_equal ".obj", msvc.default_extension(:objects)
  end

  def test_msvc_static_extension
    assert_equal ".lib", msvc.default_extension(:static)
  end

  def test_msvc_shared_extension
    assert_equal ".dll", msvc.default_extension(:shared)
  end

  def test_msvc_executable_extension
    assert_equal ".exe", msvc.default_extension(:executable)
  end

  # ---------------------------------------------------------------------------
  # ClangCL: inherits MSVC extensions
  # ---------------------------------------------------------------------------

  def clang_cl
    Class.new(MetaCC::ClangCL) do
      def command_available?(_cmd) = false
    end.new
  end

  def test_clang_cl_objects_extension
    assert_equal ".obj", clang_cl.default_extension(:objects)
  end

  def test_clang_cl_static_extension
    assert_equal ".lib", clang_cl.default_extension(:static)
  end

  def test_clang_cl_shared_extension
    assert_equal ".dll", clang_cl.default_extension(:shared)
  end

  def test_clang_cl_executable_extension
    assert_equal ".exe", clang_cl.default_extension(:executable)
  end

end
