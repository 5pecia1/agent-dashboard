# CocoaPods trunk has no 2.10.1 specification. Use the binary and checksum
# published in the upstream 2.10.1 Package.swift (MIT).
Pod::Spec.new do |s|
  s.name = 'Sparkle'
  s.version = '2.10.1'
  s.summary = 'The Sparkle software update framework for macOS.'
  s.homepage = 'https://sparkle-project.org'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.author = 'Sparkle Project'
  s.platform = :osx, '12.0'
  s.source = {
    :http => 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip',
    :sha256 => '4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a',
  }
  s.vendored_frameworks = 'Sparkle.xcframework'
  s.resource_bundles = { 'SparkleNotices' => ['LICENSE'] }
end
