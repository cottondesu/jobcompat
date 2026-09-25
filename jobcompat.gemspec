require_relative "lib/jobcompat/version"

Gem::Specification.new do |spec|
  spec.name = "jobcompat"
  spec.version = Jobcompat::VERSION
  spec.summary = "Detect Sidekiq job argument changes that can break queued jobs"
  spec.description = "Static analysis of native Sidekiq positional arity across Git revisions and rolling deployments."
  spec.authors = ["jobcompat contributors"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/cottondesu/jobcompat"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir["lib/**/*.rb", "exe/*", "docs/*.md", "README.md", "CHANGELOG.md", "SECURITY.md", "LICENSE"]
  spec.bindir = "exe"
  spec.executables = ["jobcompat"]
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = "https://github.com/cottondesu/jobcompat"
  spec.metadata["changelog_uri"] = "https://github.com/cottondesu/jobcompat/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "https://github.com/cottondesu/jobcompat/issues"
  spec.add_dependency "prism", ">= 1.9", "< 2"
end
