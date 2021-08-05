# Zabel

Zabel, is a build cacher for Xcode, using Xcodeproj and MD5, to detect and cache products for targets. Designed for CI by now. Zabel is not Bazel. 

WARNING: BE CAREFUL IN PRODUCTION ENVIRONMENT.

## Feature

- only support Cocoapods targets now
- support bundle / a / framework
- support C / C++ / Objective-C / Objective-C++ / Swift
- support Cocoapods option use_frameworks! :linkage => :dynamic and not
- support Cocoapods option use_frameworks! :linkage => :static and not
- support Cocoapods option use_modular_headers and not
- support Cocoapods option generate_multiple_pod_projects and not
- support prefix header and precompile prefix header
- support XCFrameworks
- support modulemap
- support development pods
- support different build path
- support dependent files and implicit dependent targets
- support xcodebuild build or archive
- support fastlane build or archive
- support legacy or new build system

## Installation

Please use Ruby 2.x.

Add this line to your application's Gemfile:

```ruby
source "https://rubygems.org"

gem 'zabel'
```

And then execute:

    $ bundle

Or install in local path:

    $ bundle install --path vendor/bundle

Or install it yourself as:

    $ [sudo] gem install zabel

## Usage

Simply add zabel before your xcodebuild/fastlane command. Please ensure that your command can work without zabel. 

    $ [bundle exe] zabel xcodebuild/fastlane ...

## Advanced usage

You can controll your cache keys, which can be more or less. Please ensure that your arguments are same in pre and post.

    $ [bundle exe] zabel pre -configuration Debug ...
    $ xcodebuild/fastlane ...
    $ [bundle exe] zabel post -configuration Debug ...

Importantly, configuration argument must be set with zabel.

## Options

You can custom some options by yourself.

Zabel stores caches in `~/zabel` by default. You can change this path.

    $ export ZABEL_CACHE_ROOT=xxx

Zabel uses LRU to clear unuse old caches, to keep max count with 10000 by default. You can change this number.

    $ export ZABEL_CACHE_COUNT=12345

Zable caches targets which count of source files is greater than or equal 1 by default. You can set this value to 0 or more than 1 to achieve higher total speed. 

    $ export ZABEL_MIN_SOURCE_FILE_COUNT=10

Zabel detects module map dependecy by default. However, there are bugs of xcodebuild or swift-frontend, which emits unnecessary, incorrect and even cycle modulemap dependencies. Cycle dependency targets will be miss every time. To test by run "ruby test/one.rb test/todo/modulemap_file/Podfile". You can disable this feature.

    $ export ZABEL_NOT_DETECT_MODULE_MAP_DEPENDENCY=YES

## Changelog

- 1.0.3 support bundle install
- 1.0.2 support legacy build system
- 1.0.1 support xcodebuild archive and fastlane
- 1.0.0

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Test

```bash
# test all cases
ruby test/all.rb
# test one case
ruby test/one.rb test/case/simple/Podfile
# test one todo case
ruby test/one.rb test/todo/modulemap_file/Podfile
```

## TODO

- support more projects and targets, not only Pods
- support and test more clang arguments
- support intermediate cache such as .o and .gcno
- try to support local development
- try to support remote cache server

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/WeijunDeng/Zabel. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Zabel project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/WeijunDeng/Zabel/blob/master/CODE_OF_CONDUCT.md).

## FAQ

Q: Must I set configuration ?

A: Yes, for now.

Q: How to define a cache hit ?

A: A target cache will be hit only when it matches all arguments, settings, sources and dependencies.

Q: What will happen if a cache is hit ?

A: Firstly, PBXHeadersBuildPhase and PBXSourcesBuildPhase and PBXResourcesBuildPhase of a target will be deleted to disable build. Secondly, scripts to extract cache product will be added.

Q: What about scripts ?

A: All original PBXCopyFilesBuildPhase or PBXFrameworksBuildPhase or PBXShellScriptBuildPhase will not be deleted or changed. At most time, they did not take much time. However, they are difficult to be cached.

Q: What about dependencies ?

A: Simple dependent files (headers) and implicit dependent targets will be detected. If dependent files of a target change, this target will be recompiled. If dependent targets of a target miss cache, this target and dependent targets will be recompiled. 


