# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = true
end

desc "Regenerate lib/ampost/generated from openapi.json"
task :generate do
  ruby "scripts/generate.rb"
end

task default: :test
