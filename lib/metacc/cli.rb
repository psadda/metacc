# frozen_string_literal: true

require "optparse"
require_relative "driver"

module MetaCC

  # Command-line interface for the MetaCC Driver.
  #
  # Usage:
  #   metacc <sources...> -o <output> [options]       – compile source file(s)
  class CLI

    InvalidOption = OptionParser::InvalidOption

    WARNING_CONFIGS = {
      "all" =>   :warn_all,
      "error" => :warn_error
    }

    SANITIZERS = {
      "address" =>   :asan,
      "addr" =>      :asan,
      "undefined" => :ubsan,
      "ub" =>        :ubsan,
      "memory" =>    :msan,
      "mem" =>       :msan,
      "leak" =>      :lsan
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
      "xclangcl" => ClangCL,
      "xtinycc" => TinyCC
    }.freeze

    def initialize(driver: Driver.new)
      @driver = driver
    end

    def run(argv)
      input_paths, options = parse_compile_args(argv)
      output_path = options.delete(:output_path)
      validate_options!(options[:flags], output_path, link: options[:link], run: options[:run])
      invoke(input_paths, output_path, **options)
    end

    # Parses compile arguments.
    # Returns [positional_args, options_hash].
    def parse_compile_args(argv)
      options = {
        include_paths: [],
        defs:          [],
        link:          true,
        link_paths:    [],
        libs:          [],
        output_path:   nil,
        run:           false,
        flags:         [],
        xflags:        {}
      }
      parser = OptionParser.new
      setup_compile_options(parser, options)
      input_paths = parser.permute(argv)
      [input_paths, options]
    end

    private

    def setup_compile_options(parser, options)
      parser.require_exact = true

      parser.separator ""
      parser.separator "General options:"

      parser.on("-o FILEPATH", "Output file path") do |value|
        options[:output_path] = value
      end
      parser.on("-I DIRPATH", "Add an include search directory") do |value|
        options[:include_paths] << value
      end
      parser.on("-D DEF", "Add a preprocessor definition") do |value|
        options[:defs] << value
      end
      parser.on("--std=STANDARD", "Specify the language standard") do |value|
        options[:flags] << STANDARDS[value]
      end
      parser.on("-W OPTION", "Configure warnings") do |value|
        options[:flags] << WARNING_CONFIGS[value]
      end
      parser.on("-r", "--run", "Run the compiled executable after a successful build") do
        options[:run] = true
      end

      parser.separator ""
      parser.separator "Debugging:"

      parser.on("-g", "--debug-info", "Emit debugging symbols") do
        options[:flags] << :debug_info
      end
      parser.on("-S", "--sanitize SANITIZER", "Enable sanitizer (address, undefined, leak, memory)") do |value|
        options[:flags] << SANITIZERS[value]
      end

      parser.separator ""
      parser.separator "Optimization:"

      parser.on("-O LEVEL", /\A[0-3]|s\z/, "Optimization level (0, 1, 2, 3, or s)") do |level|
        options[:flags] << :"o#{level}"
      end
      parser.on("--lto", "Enable link time optimization") do
        options[:flags] << :lto
      end
      parser.on("--omit-frame-pointer") do |value|
        options[:flags] << :omit_frame_pointer
      end
      parser.on("--strict-aliasing") do |value|
        options[:flags] << :strict_aliasing
      end

      parser.separator ""
      parser.separator "Code generation:"

      parser.on("-m", "--arch=ARCH", "Target architecture") do |value|
        options[:flags] << TARGETS[value]
      end
      parser.on("--pic", "Generate position independent code") do |value|
        options[:flags] << :pic
      end
      parser.on("--no-rtti", "Disable runtime type information") do |value|
        options[:flags] << :no_rtti
      end
      parser.on("--no-exceptions", "Disable exceptions (and unwinding info)") do |value|
        options[:flags] << :no_exceptions
      end

      parser.separator ""
      parser.separator "Linking:"

      parser.on("--static", "Produce a static library") do
        options[:flags] << :static
      end
      parser.on("--shared", "Produce a shared library") do |value|
        options[:flags] << :shared
      end
      parser.on("--shared-compat", "Produce a shared library with full LD_PRELOAD compatability") do |value|
        options[:flags] << :shared_compat
      end
      parser.on("-c", "Compile only (produce object files without linking)") do
        options[:link] = false
      end
      parser.on("-l LIB", "Link against library LIB") do |value|
        options[:libs] << value
      end
      parser.on("-L DIR", "Add linker library search path") do |value|
        options[:link_paths] << value
      end

      parser.on("-s", "--strip", "Strip unneeded symbols") do
        options[:flags] << :strip
      end

      parser.separator ""
      parser.separator "Compiler specific:"

      XFLAGS.each do |name, toolchain_class|
        toolchain_name = toolchain_class.name.split("::").last
        parser.on("--#{name} FLAG", "Forward FLAG to the compiler if compiling with #{toolchain_name}") do |value|
          options[:xflags][toolchain_class] ||= []
          options[:xflags][toolchain_class] << value
        end
      end

      parser.separator ""
      parser.separator "Informational:"

      parser.on_tail("--version", "Print the toolchain version and exit") do
        puts @driver.toolchain.version_banner
        exit
      end
      parser.on_tail("-h", "--help", "Show this message") do
        puts parser
        exit
      end
    end

    def validate_options!(flags, output_path, link:, run:)
      if !link && output_path
        raise OptionParser::InvalidOption, "cannot specify output path (-o) in compile only mode (-c)"
      end

      if link && !output_path
        raise OptionParser::InvalidOption, "must specify an output path (-o)"
      end

      if run && (!link || flags.include?(:shared) || flags.include?(:static))
        raise OptionParser::InvalidOption, "--run may not be used with -c, --shared, or --static"
      end
    end

    def invoke(input_paths, desired_output_path = nil, link: true, run: false, **options)
      if link
        actual_output_path = @driver.compile_and_link(input_paths, desired_output_path, **options)
        system(actual_output_path) if run
      else
        options.delete(:link_paths)
        options.delete(:libs)
        @driver.compile(input_paths, **options)
      end
    end

  end

end
