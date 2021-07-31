# Zabel

Zabel, is a build cacher for Xcode, using Xcodeproj and MD5, to detect and cache products for targets. Zabel is not Bazel.

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

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'zabel'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install zabel

## Usage

Simply add zabel before your xcodebuild/fastlane command. Please ensure that your command can work without zabel.

```
zabel xcodebuild/fastlane xxx 
```

## Advanced usage

You can controll your cache keys, which can be more or less. Please ensure that your arguments are same in pre and post.

```
zabel pre -configuration Release abc
xcodebuild/fastlane xxx
zabel post -configuration Release abc
```

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


