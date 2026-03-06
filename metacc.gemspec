# frozen_string_literal: true

require_relative "lib/metacc/version"

Gem::Specification.new do |spec|
  spec.name          = "metacc"
  spec.version       = MetaCC::VERSION
  spec.authors       = ["Praneeth Sadda"]
  spec.email         = "psadda@gmail.com"

  spec.summary       = "A small Ruby scripting system for building C and C++ applications"
  spec.description   = <<~DESC
    metacc provides a small set of classes for invoking C/C++ build tools, abstracting
    away differences between compilers.
  DESC
  spec.homepage = "https://github.com/psadda/metacc"
  spec.license       = "BSD-3-Clause"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb"] + Dir["bin/*"]
  spec.executables   = ["metacc"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.3.0"
end
