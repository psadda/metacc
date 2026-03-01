# frozen_string_literal: true

require "optparse"
require_relative "driver"

module MetaCC

  # Command-line interface for the MetaCC Driver.
  #
  # Usage:
  #   metacc <sources...> -o <output> [options]       – compile source file(s)
  #
  # General:
  #   -Wall -Werror
  #   --std=c11 --std=c17 --std=c23
  #   --std=c++11 --std=c++14 --std=c++17 --std=c++20 --std=c++23 --std=c++26
  #
  # Linking:
  #   --objects / -c     – compile only; don't link
  #   -l, -L             - specify linker input
  #   --shared           – produce a shared library
  #   --static           – produce a static library
  #   --lto              - enable link time optimization
  #   --strip / -s       – strip unneeded symbols
  #
  # Code generation:
  #   -O0, -O1, -O2, -O3                             - Set the optimization level
  #   -msse4.2 -mavx -mavx2 -mavx512 --arch=native   - Compile for the given target
  #   --no-rtti --no-exceptions
  #   --pic
  #
  # Debugging:
  #   --debug / -g
  #   --asan --ubsan --msan
  #
  # Toolchain-specific flags (passed to Driver#compile via xflags:):
  #   --xmsvc VALUE     – appended to xflags[MSVC]
  #   --xgnu  VALUE     – appended to xflags[GNU]
  #   --xclang VALUE    – appended to xflags[Clang]
  #   --xclangcl VALUE  – appended to xflags[ClangCL]
  class CLI

    # Maps long-form CLI flag names to Driver::RECOGNIZED_FLAGS symbols.
    # Optimization-level flags are handled separately via -O LEVEL.
    LONG_FLAGS = {
      "lto" =>                       :lto,
      "asan" =>                      :asan,
      "ubsan" =>                     :ubsan,
      "msan" =>                      :msan,
      "no-rtti" =>                   :no_rtti,
      "no-exceptions" =>             :no_exceptions,
      "pic" =>                       :pic,
      "no-semantic-interposition" => :no_semantic_interposition,
      "no-omit-frame-pointer" =>     :no_omit_frame_pointer,
      "no-strict-aliasing" =>        :no_strict_aliasing
    }.freeze

    WARNING_CONFIGS = {
      "all" =>   :warn_all,
      "error" => :warn_error
    }

    TARGETS = {
      "sse4.2" => :sse4_2,
      "avx" =>    :avx,
      "avx2" =>   :avx2,
      "avx512" => :avx512,
      "native" => :native
    }.freeze

    STANDARDS = {
      "c11" =>   :c11,
      "c17" =>   :c17,
      "c23" =>   :c23,
      "c++11" => :cxx11,
      "c++14" => :cxx14,
      "c++17" => :cxx17,
      "c++20" => :cxx20,
      "c++23" => :cxx23,
      "c++26" => :cxx26
    }.freeze

    # Maps --x<name> CLI option names to xflags toolchain-class keys.
    XFLAGS = {
      "xmsvc" => MSVC,
      "xgnu" => GNU,
      "xclang" => Clang,
      "xclangcl" => ClangCL
    }.freeze

    def initialize(driver: Driver.new)
      @driver = driver
    end

    def run(argv)
      options, input_paths = parse_compile_args(argv)
      output_path = options.delete(:output_path)
      run_flag = options.delete(:run)
      validate_options!(options[:flags], output_path, run_flag)
      invoke(input_paths, output_path, options, run: run_flag)
    end

    # Parses compile arguments.
    # Returns [options_hash, remaining_positional_args].
    def parse_compile_args(argv)
      options = {
        include_paths: [],
        defs:          [],
        linker_paths:  [],
        libs:          [],
        output_path:   nil,
        run:           false,
        flags:         [],
        xflags:        {}
      }
      parser = OptionParser.new
      setup_compile_options(parser, options)
      sources = parser.permute(argv)
      [options, sources]
    end

    private

    def setup_compile_options(parser, options)
      parser.on("-o FILEPATH", "Output file path") do |value|
        options[:output_path] = value
      end
      parser.on("-I DIRPATH", "Add an include search directory") do |value|
        options[:include_paths] << value
      end
      parser.on("-D DEF", "Add a preprocessor definition") do |value|
        options[:defs] << value
      end
      parser.on("-O LEVEL", /\A[0-3]|s\z/, "Optimization level (0–3)") do |level|
        options[:flags] << :"o#{level}"
      end
      parser.on("-m", "--arch ARCH", "Target architecture") do |value|
        options[:flags] << TARGETS[value]
      end
      parser.on("-g", "--debug", "Emit debugging symbols") do
        options[:flags] << :debug
      end
      parser.on("--std STANDARD", "Specify the language standard") do |value|
        options[:flags] << STANDARDS[value]
      end
      parser.on("-W OPTION", "Configure warnings") do |value|
        options[:flags] << WARNING_CONFIGS[value]
      end
      parser.on("-c", "--objects", "Produce object files") do
        options[:flags] << :objects
      end
      parser.on("-r", "--run", "Run the compiled executable after a successful build") do
        options[:run] = true
      end
      parser.on("-l LIB", "Link against library LIB") do |value|
        options[:libs] << value
      end
      parser.on("-L DIR", "Add linker library search path") do |value|
        options[:linker_paths] << value
      end
      parser.on("--shared", "Produce a shared library") do
        options[:flags] << :shared
      end
      parser.on("--static", "Produce a static library") do
        options[:flags] << :static
      end
      parser.on("-s", "--strip", "Strip unneeded symbols") do
        options[:flags] << :strip
      end
      LONG_FLAGS.each do |name, sym|
        parser.on("--#{name}") do
          options[:flags] << sym
        end
      end
      XFLAGS.each do |name, tc_class|
        parser.on("--#{name} VALUE", "Pass VALUE to the #{tc_class} toolchain") do |value|
          options[:xflags][tc_class] ||= []
          options[:xflags][tc_class] << value
        end
      end
      parser.on_tail("--version", "Print the toolchain version and exit") do
        puts @driver.toolchain&.version_banner
        exit
      end
    end

    def validate_options!(flags, output_path, run_flag)
      objects = flags.include?(:objects)

      if objects && output_path
        warn "error: -o cannot be used with --objects"
        exit 1
      end

      unless objects || output_path
        warn "error: -o is required"
        exit 1
      end

      return unless run_flag && (objects || flags.include?(:shared) || flags.include?(:static))

      warn "error: --run cannot be used with --objects, --shared, or --static"
      exit 1
    end

    def run_executable(path)
      system(path)
    end

    def invoke(input_paths, output_path, options, run: false)
      result = @driver.invoke(input_paths, output_path, **options)
      exit 1 unless result
      run_executable(result) if run
    end

  end

end
