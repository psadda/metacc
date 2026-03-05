# frozen_string_literal: true

require "rbconfig"

module MetaCC

  # Base class for compiler toolchains.
  # Subclasses set their own command attributes in +initialize+ by calling
  # +command_available?+ to probe the system, then implement the
  # toolchain-specific flag and command building methods.
  #   c    – command used to compile source files
  class Toolchain

    attr_reader :c

    def initialize(search_paths: [])
      @search_paths = search_paths
    end

    # Returns true if this toolchain's primary compiler can be found
    def available?
      command_available?(c)
    end

    # Returns the languages supported by this toolchain as an array of symbols.
    # The default implementation returns [:c, :cxx].  Subclasses that only
    # support a subset of languages should override this method.
    def languages
      %i[c cxx]
    end

    # Returns true if +command+ is present in PATH, false otherwise.
    # Intentionally ignores the exit status – only ENOENT (not found) matters.
    def command_available?(command)
      !system(command, "--version", out: File::NULL, err: File::NULL).nil?
    end

    # Returns the output of running the compiler with --version.
    def version_banner
      IO.popen([c, "--version", { err: :out }], &:read)
    end

    # Returns a Hash mapping universal flags to native flags for this toolchain.
    def flags
      raise "#{self.class}#flags not implemented"
    end

    # Returns the full command array for the given inputs, output, and flags.
    # The output mode (object files, shared library, static library, or
    # executable) is determined by the translated flags.
    def compile_command(
      input_files,
      flags:,
      include_paths:,
      defs:
    )
      raise "#{self.class}#command not implemented"
    end

    def compile_and_link_commands(
      input_files,
      output_file,
      flags:,
      include_paths:,
      defs:,
      link_paths:,
      libs:
    )
      raise "#{self.class}#command not implemented"
    end

    # Returns the default file extension (with leading dot, e.g. ".o") for the
    # given output type on this toolchain/OS combination.  Returns an empty
    # string when no extension is conventional (e.g. executables on Unix).
    #
    # @param output_type [:objects, :shared, :static, :executable]
    # @return [String]
    def default_extension(output_type)
      host_os = RbConfig::CONFIG["host_os"]
      case output_type
      when :objects    then ".o"
      when :static     then ".a"
      when :shared
        if host_os.match?(/mswin|mingw|cygwin/)
          ".dll"
        elsif host_os.match?(/darwin/)
          ".dylib"
        else
          ".so"
        end
      when :executable
        host_os.match?(/mswin|mingw|cygwin/) ? ".exe" : ""
      else
        raise ArgumentError, "unknown output_type: #{output_type.inspect}"
      end
    end

    private

    def c_file?(path)
      File.extname(path).downcase == ".c"
    end

    # Returns the full path to +name+ if it is found (and executable) in one of
    # the configured search paths, otherwise returns +name+ unchanged so that
    # the shell's PATH is used at execution time.
    def resolve_command(name)
      @search_paths.each do |dir|
        full_path = File.join(dir, name)
        return full_path if File.executable?(full_path)
      end
      name
    end

  end

  # Base class for GNU compatible (ish) toolchains
  class GNU < Toolchain

    def initialize(cc_command = "gcc", search_paths: [])
      super(search_paths:)
      @c = resolve_command(cc_command)
    end

    def compile_command(
      input_files,
      flags:,
      include_paths:,
      defs:
    )
      inc_flags = include_paths.map { |p| "-I#{p}" }
      def_flags = defs.map { |d| "-D#{d}" }
      [c, "-c", *flags, *inc_flags, *def_flags, *input_files]
    end

    def compile_and_link_commands(
      input_files,
      output_file,
      flags:,
      include_paths:,
      defs:,
      link_paths:,
      libs:
    )
      inc_flags = include_paths.map { |p| "-I#{p}" }
      def_flags = defs.map { |d| "-D#{d}" }
      lib_path_flags = link_paths.map { |p| "-L#{p}" }
      lib_flags      = libs.map { |l| "-l#{l}" }
      [[c, *flags, *inc_flags, *def_flags, *input_files, *lib_path_flags, *lib_flags, "-o", output_file]]
    end

    GNU_FLAGS = {
      o0:                    ["-O0"],
      o1:                    ["-O1"],
      o2:                    ["-O2"],
      o3:                    ["-O3"],
      os:                    ["-Os"],
      sse4_2:                ["-march=x86-64-v2"], # This is a better match for /arch:SSE4.2 than -msse4_2 is
      avx:                   ["-march=x86-64-v2", "-mavx"],
      avx2:                  ["-march=x86-64-v3"], # This is a better match for /arch:AVX2 than -mavx2 is
      avx512:                ["-march=x86-64-v4"],
      native:                ["-march=native", "-mtune=native"],
      debug_info:            ["-g3"],
      lto:                   ["-flto"],
      warn_all:              ["-Wall", "-Wextra", "-pedantic"],
      warn_error:            ["-Werror"],
      c11:                   ["-std=c11"],
      c17:                   ["-std=c17"],
      c23:                   ["-std=c23"],
      cxx11:                 ["-std=c++11"],
      cxx14:                 ["-std=c++14"],
      cxx17:                 ["-std=c++17"],
      cxx20:                 ["-std=c++20"],
      cxx23:                 ["-std=c++23"],
      cxx26:                 ["-std=c++2c"],
      asan:                  ["-fsanitize=address"],
      ubsan:                 ["-fsanitize=undefined"],
      msan:                  ["-fsanitize=memory"],
      lsan:                  ["-fsanitize=leak"],
      no_rtti:               ["-fno-rtti"],
      no_exceptions:         ["-fno-exceptions", "-fno-unwind-tables"],
      pic:                   ["-fPIC"],
      omit_frame_pointer:    ["-fomit-frame-pointer"],
      no_omit_frame_pointer: ["-fno-omit-frame-pointer"],
      strict_aliasing:       ["-fstrict-aliasing"],
      no_strict_aliasing:    ["-fno-strict-aliasing"],
      shared:                ["-shared", "-Bsymbolic-non-weak-functions", "-fno-semantic-interposition"],
      shared_compat:         ["-shared"],
      static:                ["-static"],
      strip:                 ["-Wl,--strip-unneeded"],
      debug:                 ["-D_GLIBCXX_DEBUG", "-fasynchronous-unwind-tables"]
    }.freeze

  end

  class GCC < GNU

    def initialize(search_paths: [])
      super("gcc", search_paths:)
    end

    def flags
      GNU_FLAGS
    end

  end

  # Clang toolchain – identical command structure to GNU.
  class Clang < GNU

    def initialize(search_paths: [])
      super("clang", search_paths:)
    end

    CLANG_FLAGS = GNU_FLAGS.merge(lto: ["-flto=thin"]).freeze

    def flags
      CLANG_FLAGS
    end

  end

  # Microsoft Visual C++ toolchain.
  class MSVC < Toolchain

    # Default location of the Visual Studio Installer's vswhere utility.
    VSWHERE_PATH = File.join(
      ENV.fetch("ProgramFiles(x86)", "C:\\Program Files (x86)"),
      "Microsoft Visual Studio", "Installer", "vswhere.exe"
    ).freeze

    def initialize(cl_command = "cl", search_paths: [])
      super(search_paths:)
      resolved_cmd = resolve_command(cl_command)
      @c = resolved_cmd
      setup_msvc_environment(resolved_cmd)
    end

    def compile_command(
      input_files,
      flags:,
      include_paths:,
      defs:
    )
      inc_flags = include_paths.map { |p| "/I#{p}" }
      def_flags = defs.map { |d| "/D#{d}" }
      [c, "/c", *flags, *inc_flags, *def_flags, *input_files]
    end

    def compile_and_link_commands(
      input_files,
      output_file,
      flags:,
      include_paths:,
      defs:,
      link_paths:,
      libs:
    )
      inc_flags = include_paths.map { |p| "/I#{p}" }
      def_flags = defs.map { |d| "/D#{d}" }
      lib_flags      = libs.map { |l| "#{l}.lib" }
      lib_path_flags = link_paths.map { |p| "/LIBPATH:#{p}" }
      cmd = [c, *flags, *inc_flags, *def_flags, *input_files, *lib_flags, "/Fe#{output_file}"]
      cmd += ["/link", *lib_path_flags] unless lib_path_flags.empty?
      [cmd]
    end

    MSVC_FLAGS = {
      o0:                    ["/Od"],
      o1:                    ["/O1"],
      o2:                    ["/O2"],
      o3:                    ["/O2", "/Ob3"],
      os:                    ["/O1"],
      sse4_2:                ["/arch:SSE4.2"],
      avx:                   ["/arch:AVX"],
      avx2:                  ["/arch:AVX2"],
      avx512:                ["/arch:AVX512"],
      native:                [],
      debug_info:            ["/Zi"],
      lto:                   ["/GL"],
      warn_all:              ["/W4"],
      warn_error:            ["/WX"],
      c11:                   ["/std:c11"],
      c17:                   ["/std:c17"],
      c23:                   ["/std:clatest"],
      cxx11:                 [],
      cxx14:                 ["/std:c++14"],
      cxx17:                 ["/std:c++17"],
      cxx20:                 ["/std:c++20"],
      cxx23:                 ["/std:c++23preview"],
      cxx26:                 ["/std:c++latest"],
      asan:                  ["/fsanitize=address"],
      ubsan:                 [],
      msan:                  [],
      lsan:                  [],
      no_rtti:               ["/GR-"],
      no_exceptions:         ["/EHs-", "/EHc-"],
      pic:                   [],
      omit_frame_pointer:    ["/Oy"],
      no_omit_frame_pointer: ["/Oy-"],
      strict_aliasing:       [],
      no_strict_aliasing:    [],
      shared:                ["/LD"],
      shared_compat:         ["/LD"],
      static:                ["/c"],
      strip:                 []
    }.freeze

    def flags
      MSVC_FLAGS
    end

    # MSVC and clang-cl always target Windows, so extensions are Windows-specific
    # regardless of the host OS.
    def default_extension(output_type)
      case output_type
      when :objects    then ".obj"
      when :static     then ".lib"
      when :shared     then ".dll"
      when :executable then ".exe"
      else
        raise ArgumentError, "unknown output_type: #{output_type.inspect}"
      end
    end

    # MSVC prints its version banner to stderr when invoked with no arguments.
    def show_version
      IO.popen([c, { err: :out }], &:read)
    end

    private

    # Attempts to configure the MSVC environment using vswhere.exe when cl.exe
    # is not already available on PATH.  Tries two vswhere strategies in order:
    #
    # 1. Query vswhere for VS instances whose tools are already on PATH (-path).
    # 2. Query vswhere for the latest VS instance, including prereleases.
    #
    # When a VS instance is found, locates vcvarsall.bat relative to the
    # returned devenv.exe path and runs it so that cl.exe and related tools
    # become available on PATH.
    def setup_msvc_environment(cl_command)
      return if command_available?(cl_command)

      devenv_path = MSVC.vswhere("-path", "-property", "productPath") ||
                    MSVC.vswhere("-latest", "-prerelease", "-property", "productPath")
      return unless devenv_path

      MSVC.vcvarsall(devenv_path)
    end

    # Runs vswhere.exe with the given arguments and returns the trimmed stdout,
    # or nil if vswhere.exe is absent, the command fails, or produces no output.
    def self.vswhere(*args)
      path = IO.popen([VSWHERE_PATH, *args], &:read).strip
      status = $?

      status.success? && !path.empty? ? path : nil
    rescue Errno::ENOENT
      nil
    end

    # Runs vcvarsall.bat for the x64 architecture and merges the resulting
    # environment variables into the current process's ENV so that cl.exe
    # and related tools become available on PATH.
    #
    # Finds the path to vcvarsall.bat for the given devenv.exe path, or nil
    # if it cannot be located.  devenv.exe lives at:
    #   <root>\Common7\IDE\devenv.exe
    # vcvarsall.bat lives at:
    #   <root>\VC\Auxiliary\Build\vcvarsall.bat
    #
    # Parses the output of `vcvarsall.bat … && set` and merges the resulting
    # environment variables into the current process's ENV.
    def MSVC.vcvarsall(devenv_path)
      # See https://stackoverflow.com/a/19929778
      return if ENV.has_key?("DevEnvDir")

      # Calculate the location of vcvarsall.bat
      install_root = File.expand_path("../../..", devenv_path)

      # Check if a file is actually present there
      vcvarsall = File.join(install_root, "VC", "Auxiliary", "Build", "vcvarsall.bat")
      return unless File.exist?(vcvarsall)

      # Run vcvarsall.bat and dump the environment to the shell
      output = `"#{vcvarsall}" x64 && set`
      status = $?
      return unless status.success?

      output.each_line do |line|
        key, value = line.chomp.split("=", 2)
        next if value.to_s.empty?

        ENV[key] = value
      end
    end

  end

  # clang-cl toolchain – uses clang-cl compiler with MSVC-compatible flags and
  # environment setup.
  class ClangCL < MSVC

    def initialize(search_paths: [])
      super("clang-cl", search_paths:)
    end

    CLANG_CL_FLAGS = MSVC_FLAGS.merge(
      o3:                 ["/Ot"],       # Clang-CL treats /Ot as -O3
      lto:                ["-flto=thin"]
      strict_aliasing:    ["/clang:-fstrict-aliasing"]
      no_strict_aliasing: ["/clang:-fno-strict-aliasing"]
    ).freeze

    def flags
      CLANG_CL_FLAGS
    end

  end

  # TinyCC toolchain (tcc).  TinyCC only supports C, not C++.
  class TinyCC < GNU

    def initialize(search_paths: [])
      super("tcc", search_paths:)
      @ar = resolve_command("ar")
    end

    def compile_and_link_commands(input_files, output_file, **options)
      commands = super(input_files, output_file, **options)
      if options[:flags].include?(:static)
        object_files = input_files.map { |f| f.sub(/\.c\z/, ".o") }
        commands << [@ar, "rcs", output_file, *object_files]
      end
      commands
    end

    # TinyCC does not support C++.
    def languages
      [:c]
    end

    def version_banner
      IO.popen([c, "-v", { err: :out }], &:read)
    end

    TINYCC_FLAGS = {
      o0:                 [],
      o1:                 ["-O1"],
      o2:                 ["-O2"],
      o3:                 ["-O2"],
      os:                 [],
      sse4_2:             [],
      avx:                [],
      avx2:               [],
      avx512:             [],
      native:             [],
      debug_info:         ["-g"],
      lto:                [],
      warn_all:           ["-Wall"],
      warn_error:         ["-Werror"],
      c11:                [],
      c17:                [],
      c23:                [],
      cxx11:              [],
      cxx14:              [],
      cxx17:              [],
      cxx20:              [],
      cxx23:              [],
      cxx26:              [],
      asan:               [],
      ubsan:              [],
      msan:               [],
      leak:               [],
      no_rtti:            [],
      no_exceptions:      [],
      pic:                [],
      keep_frame_pointer: [],
      relaxed_aliasing:   [],
      shared:             ["-shared"],
      shared_compat:      ["-shared"],
      static:             ["-c"],
      strip:              []
    }.freeze

    def flags
      TINYCC_FLAGS
    end

  end

end
