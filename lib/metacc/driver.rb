# frozen_string_literal: true

require "open3"
require_relative "toolchain"

module MetaCC

  # Raised when no supported C/C++ compiler can be found on the system.
  class CompileError < StandardError; end

  # Raised when no supported C/C++ compiler can be found on the system.
  class ToolchainNotFoundError < StandardError; end

  # Driver wraps C and C++ compile and link operations using the first
  # available compiler found on the system (Clang, GCC, or MSVC).
  class Driver

    RECOGNIZED_FLAGS = Set.new(
      %i[
        warn_all warn_error
        c11 c17 c23
        cxx11 cxx14 cxx17 cxx20 cxx23 cxx26
        o0 o1 o2 o3 os lto
        sse4_2 avx avx2 avx512 native
        asan ubsan msan lsan
        debug_info
        omit_frame_pointer strict_aliasing
        no_rtti no_exceptions
        pic shared shared_compat static strip
      ]
    ).freeze

    # The detected toolchain (a Toolchain subclass instance).
    attr_reader :toolchain

    # Detects the first available C/C++ compiler toolchain.
    #
    # @param prefer       [Array<Class>] toolchain classes to probe, in priority order.
    #                                   Each element must be a Class derived from Toolchain.
    #                                   Defaults to [Clang, GNU, MSVC].
    # @param search_paths [Array<String>] directories to search for toolchain executables
    #                                    before falling back to PATH. Defaults to [].
    # @raise [ToolchainNotFoundError] if no supported compiler is found.
    def initialize(prefer: [MSVC], search_paths: [])
      @toolchain = select_toolchain!(prefer, search_paths)
    end

    # Invokes the compiler driver for the given input files and output path,
    # compiling and producting object files without linking.
    #
    # @param input_files    [String, Array<String>] paths to the input files
    # @param flags          [Array<Symbol>] compiler/linker flags
    # @param xflags         [Hash{Class => String}] extra (native) compiler flags keyed by toolchain Class
    # @param include_paths  [Array<String>] directories to add with -I
    # @param defs           [Array<String>] preprocessor macros (e.g. "FOO" or "FOO=1")
    # @param env            [Hash] environment variables to set for the subprocess
    # @param working_dir    [String] working directory for the subprocess (default: ".")
    # @raise [CompileError] if the underlying toolchain executable returns a non-zero exit status
    def compile(
      input_files,
      flags: [],
      xflags: {},
      include_paths: [],
      defs: [],
      env: {},
      working_dir: "."
    )
      flags = translate_flags(flags)
      flags.concat(xflags[@toolchain.class] || [])

      cmd = @toolchain.compile_command(
        input_files,
        flags:,
        include_paths:,
        defs:
      )

      !!run_command(cmd, env:, working_dir:)
    end

    # Invokes the compiler driver for the given input files and output path.
    # The kind of output (object files, executable, shared library, or static
    # library) is determined by the flags: +:shared+ or +:static+. When none of
    # these mode flags is present, an executable is produced.
    #
    # @param input_files    [String, Array<String>] paths to the input files
    # @param output_path    [String] path for the resulting output file
    # @param flags          [Array<Symbol>] compiler/linker flags
    # @param xflags         [Hash{Class => String}] extra (native) compiler flags keyed by toolchain Class
    # @param include_paths  [Array<String>] directories to add with -I
    # @param defs           [Array<String>] preprocessor macros (e.g. "FOO" or "FOO=1")
    # @param linker_paths   [Array<String>] linker library search paths (-L / /LIBPATH:)
    # @param libs           [Array<String>] library names to link (e.g. "m", "pthread")
    # @param env            [Hash] environment variables to set for the subprocess
    # @param working_dir    [String] working directory for the subprocess (default: ".")
    # @return [String] the (possibly extension-augmented) output path on success
    # @raise [CompileError] if the underlying toolchain executable returns a non-zero exit status
    def compile_and_link(
      input_files,
      output_path,
      flags: [],
      xflags: {},
      include_paths: [],
      defs: [],
      link_paths: [],
      libs: [],
      env: {},
      working_dir: "."
    )
      output_type = if flags.include?(:shared)  then :shared
                    elsif flags.include?(:static)  then :static
                    else :executable
                    end
      output_path = apply_default_extension(output_path, output_type)

      flags = translate_flags(flags)
      flags.concat(xflags[@toolchain.class] || [])

      cmds = @toolchain.compile_and_link_commands(
        input_files,
        output_path,
        flags:,
        include_paths:,
        defs:,
        libs:,
        link_paths:
      )

      cmds.each { |cmd| run_command(cmd, env:, working_dir:) }
      output_path
    end

    private

    def select_toolchain!(candidates, search_paths)
      candidates.each do |toolchain_class|
        toolchain = toolchain_class.new(search_paths:)
        return toolchain if toolchain.available?
      end
      candidate_names = candidates.map { |candidate| candidate.name.split("::").last }
      raise ToolchainNotFoundError, "no supported C/C++ toolchain found (tried #{candidate_names.join(", ")})"
    end

    def apply_default_extension(path, output_type)
      return path unless File.extname(path).empty?

      ext = @toolchain.default_extension(output_type)
      ext.empty? ? path : "#{path}#{ext}"
    end

    def translate_flags(flags)
      unrecognized_flag = flags.find { |flag| !RECOGNIZED_FLAGS.include?(flag) }
      if unrecognized_flag
        raise "#{unrecognized_flag.inspect} is not a known flag"
      end

      flags << :no_omit_frame_pointer unless flags.include?(:omit_frame_pointer)
      flags << :no_strict_aliasing unless flags.include?(:strict_aliasing)

      flags.flat_map { |flag| @toolchain.flags[flag] }
    end

    def run_command(cmd, env: {}, working_dir: ".")
      _out, err, status = Open3.capture3(env, *cmd, chdir: working_dir)
      raise CompileError, err unless status.success?
    end

  end

end
