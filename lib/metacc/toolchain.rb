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

    # Returns true if this toolchain's primary compiler is present in PATH.
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
      return false if command.nil?

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
    def command(_input_files, _output, _flags, _include_paths, _definitions, _libs, _linker_include_dirs)
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

  # GNU-compatible toolchain (gcc).
  class GNU < Toolchain

    def initialize(search_paths: [])
      super
      @c = resolve_command("gcc")
    end

    def command(input_files, output, flags, include_paths, definitions, libs, linker_include_dirs)
      inc_flags = include_paths.map { |p| "-I#{p}" }
      def_flags = definitions.map { |d| "-D#{d}" }
      link_mode = !flags.include?("-c")
      lib_path_flags = link_mode ? linker_include_dirs.map { |p| "-L#{p}" } : []
      lib_flags      = link_mode ? libs.map { |l| "-l#{l}" } : []
      cmd = [c, *flags, *inc_flags, *def_flags, *input_files, *lib_path_flags, *lib_flags]
      output.nil? ? cmd : [*cmd, "-o", output]
    end

    GNU_FLAGS = {
      o0:                        ["-O0"],
      o1:                        ["-O1"],
      o2:                        ["-O2"],
      o3:                        ["-O3"],
      os:                        ["-Os"],
      sse4_2:                    ["-march=x86-64-v2"], # This is a better match for /arch:SSE4.2 than -msse4_2 is
      avx:                       ["-march=x86-64-v2", "-mavx"],
      avx2:                      ["-march=x86-64-v3"], # This is a better match for /arch:AVX2 than -mavx2 is
      avx512:                    ["-march=x86-64-v4"],
      native:                    ["-march=native", "-mtune=native"],
      debug:                     ["-g3"],
      lto:                       ["-flto"],
      warn_all:                  ["-Wall", "-Wextra", "-pedantic"],
      warn_error:                ["-Werror"],
      c11:                       ["-std=c11"],
      c17:                       ["-std=c17"],
      c23:                       ["-std=c23"],
      cxx11:                     ["-std=c++11"],
      cxx14:                     ["-std=c++14"],
      cxx17:                     ["-std=c++17"],
      cxx20:                     ["-std=c++20"],
      cxx23:                     ["-std=c++23"],
      cxx26:                     ["-std=c++2c"],
      asan:                      ["-fsanitize=address"],
      ubsan:                     ["-fsanitize=undefined"],
      msan:                      ["-fsanitize=memory"],
      no_rtti:                   ["-fno-rtti"],
      no_exceptions:             ["-fno-exceptions", "-fno-unwind-tables"],
      pic:                       ["-fPIC"],
      no_semantic_interposition: ["-fno-semantic-interposition"],
      no_omit_frame_pointer:     ["-fno-omit-frame-pointer"],
      no_strict_aliasing:        ["-fno-strict-aliasing"],
      objects:                   ["-c"],
      shared:                    ["-shared"],
      static:                    ["-static"],
      strip:                     ["-Wl,--strip-unneeded"]
    }.freeze

    def flags
      GNU_FLAGS
    end

  end

  # Clang toolchain – identical command structure to GNU.
  class Clang < GNU

    def initialize(search_paths: [])
      super
      @c = resolve_command("clang")
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

    def command(input_files, output, flags, include_paths, definitions, libs, linker_include_dirs)
      inc_flags = include_paths.map { |p| "/I#{p}" }
      def_flags = definitions.map { |d| "/D#{d}" }

      if flags.include?("/c")
        cmd = [c, *flags, *inc_flags, *def_flags, *input_files]
        output.nil? ? cmd : [*cmd, "/Fo#{output}"]
      else
        lib_flags      = libs.map { |l| "#{l}.lib" }
        lib_path_flags = linker_include_dirs.map { |p| "/LIBPATH:#{p}" }
        cmd = [c, *flags, *inc_flags, *def_flags, *input_files, *lib_flags, "/Fe#{output}"]
        cmd += ["/link", *lib_path_flags] unless lib_path_flags.empty?
        cmd
      end
    end

    MSVC_FLAGS = {
      o0:                        ["/Od"],
      o1:                        ["/O1"],
      o2:                        ["/O2"],
      o3:                        ["/O2", "/Ob3"],
      os:                        ["/O1"],
      sse4_2:                    ["/arch:SSE4.2"],
      avx:                       ["/arch:AVX"],
      avx2:                      ["/arch:AVX2"],
      avx512:                    ["/arch:AVX512"],
      native:                    [],
      debug:                     ["/Zi"],
      lto:                       ["/GL"],
      warn_all:                  ["/W4"],
      warn_error:                ["/WX"],
      c11:                       ["/std:c11"],
      c17:                       ["/std:c17"],
      c23:                       ["/std:clatest"],
      cxx11:                     [],
      cxx14:                     ["/std:c++14"],
      cxx17:                     ["/std:c++17"],
      cxx20:                     ["/std:c++20"],
      cxx23:                     ["/std:c++23preview"],
      cxx26:                     ["/std:c++latest"],
      asan:                      ["/fsanitize=address"],
      ubsan:                     [],
      msan:                      [],
      no_rtti:                   ["/GR-"],
      no_exceptions:             ["/EHs-", "/EHc-"],
      pic:                       [],
      no_semantic_interposition: [],
      no_omit_frame_pointer:     ["/Oy-"],
      no_strict_aliasing:        [],
      objects:                   ["/c"],
      shared:                    ["/LD"],
      static:                    ["/c"],
      strip:                     []
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

      devenv_path = run_vswhere("-path", "-property", "productPath") ||
                    run_vswhere("-latest", "-prerelease", "-property", "productPath")
      return unless devenv_path

      vcvarsall = find_vcvarsall(devenv_path)
      return unless vcvarsall

      run_vcvarsall(vcvarsall)
    end

    # Runs vswhere.exe with the given arguments and returns the trimmed stdout,
    # or nil if vswhere.exe is absent, the command fails, or produces no output.
    def run_vswhere(*args)
      return nil unless File.exist?(VSWHERE_PATH)

      stdout = IO.popen([VSWHERE_PATH, *args], &:read)
      status = $?
      return nil unless status.success?

      path = stdout.strip
      path.empty? ? nil : path
    rescue Errno::ENOENT
      nil
    end

    # Returns the path to vcvarsall.bat for the given devenv.exe path, or nil
    # if it cannot be located.  devenv.exe lives at:
    #   <root>\Common7\IDE\devenv.exe
    # vcvarsall.bat lives at:
    #   <root>\VC\Auxiliary\Build\vcvarsall.bat
    def find_vcvarsall(devenv_path)
      install_root = File.expand_path("../../..", devenv_path)
      vcvarsall = File.join(install_root, "VC", "Auxiliary", "Build", "vcvarsall.bat")
      File.exist?(vcvarsall) ? vcvarsall : nil
    end

    # Runs vcvarsall.bat for the x64 architecture and merges the resulting
    # environment variables into the current process's ENV so that cl.exe
    # and related tools become available on PATH.
    def run_vcvarsall(vcvarsall)
      stdout = IO.popen(["cmd.exe", "/c", vcvarsall_command(vcvarsall)], &:read)
      status = $?
      return unless status.success?

      load_vcvarsall(stdout)
    end

    # Builds the cmd.exe command string for calling vcvarsall.bat and capturing
    # the resulting environment variables.  The path is double-quoted to handle
    # spaces; any embedded double quotes are escaped by doubling them, which is
    # the cmd.exe convention inside a double-quoted string.  Shellwords is not
    # used here because it produces POSIX sh escaping, which is incompatible
    # with cmd.exe syntax.
    def vcvarsall_command(vcvarsall)
      quoted = '"' + vcvarsall.gsub('"', '""') + '"'
      "#{quoted} x64 && set"
    end

    # Parses the output of `vcvarsall.bat … && set` and merges the resulting
    # environment variables into the current process's ENV.
    def load_vcvarsall(output)
      output.each_line do |line|
        key, sep, value = line.chomp.partition("=")
        next if sep.empty?

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
      o3:  ["/Ot"],       # Clang-CL treats /Ot as -O3
      lto: ["-flto=thin"]
    ).freeze

    def flags
      CLANG_CL_FLAGS
    end

  end

  # TinyCC toolchain (tcc).  TinyCC only supports C, not C++.
  class TinyCC < Toolchain

    def initialize(search_paths: [])
      super
      @c = resolve_command("tcc")
    end

    # TinyCC does not support C++.
    def languages
      [:c]
    end

    def command(input_files, output, flags, include_paths, definitions, libs, linker_include_dirs)
      inc_flags = include_paths.map { |p| "-I#{p}" }
      def_flags = definitions.map { |d| "-D#{d}" }
      link_mode = !flags.include?("-c")
      lib_path_flags = link_mode ? linker_include_dirs.map { |p| "-L#{p}" } : []
      lib_flags      = link_mode ? libs.map { |l| "-l#{l}" } : []
      cmd = [c, *flags, *inc_flags, *def_flags, *input_files, *lib_path_flags, *lib_flags]
      output.nil? ? cmd : [*cmd, "-o", output]
    end

    TINYCC_FLAGS = {
      o0:                        [],
      o1:                        ["-O1"],
      o2:                        ["-O2"],
      o3:                        ["-O2"],
      os:                        [],
      sse4_2:                    [],
      avx:                       [],
      avx2:                      [],
      avx512:                    [],
      native:                    [],
      debug:                     ["-g"],
      lto:                       [],
      warn_all:                  ["-Wall"],
      warn_error:                ["-Werror"],
      c11:                       [],
      c17:                       [],
      c23:                       [],
      cxx11:                     [],
      cxx14:                     [],
      cxx17:                     [],
      cxx20:                     [],
      cxx23:                     [],
      cxx26:                     [],
      asan:                      [],
      ubsan:                     [],
      msan:                      [],
      no_rtti:                   [],
      no_exceptions:             [],
      pic:                       [],
      no_semantic_interposition: [],
      no_omit_frame_pointer:     [],
      no_strict_aliasing:        [],
      objects:                   ["-c"],
      shared:                    ["-shared"],
      static:                    ["-c", "-static"],
      strip:                     []
    }.freeze

    def flags
      TINYCC_FLAGS
    end

  end

end
