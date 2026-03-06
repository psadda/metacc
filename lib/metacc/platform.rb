# frozen_string_literal: true

require "rbconfig"

module MetaCC

  module Platform

    def self.windows?
      @windows ||= RbConfig::CONFIG["host_os"].match?(/mswin|mingw32|windows/)
    end

    def self.cygwin?
      @cygwin ||= RbConfig::CONFIG["host_os"].match?(/cygwin/)
    end

    def self.apple?
      @apple ||= RbConfig::CONFIG["host_os"].match?(/darwin/)
    end

    def self.executable_ext
      if windows? || cygwin?
        ".exe"
      elsif apple?
        ".dylib"
      else
        ""
      end
    end

    def self.executable_ext
      windows? || cygwin? ? ".exe" : ""
    end

    def self.shared_library_ext
      if windows? || cygwin?
        ".dll"
      elsif apple?
        ".dylib"
      else
        ".so"
      end
    end

  end

end
