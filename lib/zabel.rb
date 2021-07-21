require "zabel/version"

require 'xcodeproj'
require 'digest'
require 'set'
require 'open3'
require "find"
require 'yaml'
require 'pathname'

module Zabel
  class Error < StandardError; end

  BUILD_KEY_SYMROOT = "SYMROOT"
  BUILD_KEY_TARGET_BUILD_DIR = "TARGET_BUILD_DIR"
  BUILD_KEY_OBJROOT = "OBJROOT"
  BUILD_KEY_TARGET_TEMP_DIR = "TARGET_TEMP_DIR"
  BUILD_KEY_PODS_XCFRAMEWORKS_BUILD_DIR = "PODS_XCFRAMEWORKS_BUILD_DIR"
  BUILD_KEY_MODULEMAP_FILE = "MODULEMAP_FILE"
  BUILD_KEY_SRCROOT = "SRCROOT"
  BUILD_KEY_WRAPPER_NAME = "WRAPPER_NAME"

  STATUS_HIT = "hit"
  STATUS_MISS = "miss"

  STAGE_CLEAN = "clean"
  STAGE_EXTRACT = "extract"
  STAGE_PRINTENV = "printenv"
  STAGE_PRE = "pre"
  STAGE_POST = "post"

  FILE_NAME_MESSAGE = "message.txt"
  FILE_NAME_CONTEXT = "context.yml"
  FILE_NAME_PRODUCT = "product.tar"
  FILE_NAME_TARGET_CONTEXT = "zabel_target_context.yml"
  
  def self.zabel_get_cache_root
      cache_root = ENV["ZABEL_CACHE_ROOT"]
      if cache_root and cache_root.size > 0
          return cache_root
      end
  
      return Dir.home + "/zabel"
  end
  
  def self.zabel_get_cache_count
      cache_count = ENV["ZABEL_CACHE_COUNT"]
      if cache_count and cache_count.to_i.to_s == cache_count
          return cache_count.to_i
      end
      return 10000
  end
  
  def self.zabel_should_not_detect_module_map_dependency
      # By default, zabel detects module map dependency. 
      # However, there are bugs of xcodebuild or swift-frontend, which emits unnecessary and incorrect modulemap dependencies. 
      # To test by run "ruby test/todo/modulemap_file/test.rb"
      # To avoid by set "export ZABEL_NOT_DETECT_MODULE_MAP_DEPENDENCY=YES"
      zabel_should_not_detect_module_map_dependency = ENV["ZABEL_NOT_DETECT_MODULE_MAP_DEPENDENCY"]
      if zabel_should_not_detect_module_map_dependency == "YES"
          return true
      end
      return false
  end

  def self.zabel_get_min_source_file_count
      # By default, zable caches targets which count of source files is greater than or equal 1.
      # You can set this value to 0 or more than 1 to achieve higher speed. 
      min_source_file_count = ENV["ZABEL_MIN_SOURCE_FILE_COUNT"]
      if min_source_file_count and min_source_file_count.to_i.to_s == min_source_file_count
          return min_source_file_count.to_i
      end
      return 1
  end

  def self.zabel_should_extract_once
      # By default, to achieve better compatibility, zabel extracts target cache ondemand, 
      # which means it depends on original dependencies of targets and it is in parallel.
      # However, extracting once in a shell script build phase rather than multiple shell script build phases, 
      # is a little bit faster in some cases.
      # You can enable this by set "export ZABEL_EXTRACT_ONCE=YES"
      should_extract_once = ENV["ZABEL_EXTRACT_ONCE"]
      if should_extract_once == "YES"
          return true
      end
      return false
  end

  def self.zabel_get_projects
      # TODO: to support more project, not only Pods
      pods_project = Xcodeproj::Project.open("Pods/Pods.xcodeproj")
      wrapper_project_paths = zabel_get_wrapper_project_paths(pods_project)
      wrapper_projects = []
      wrapper_project_paths.each do | path |
          next if path.end_with? "Pods/Pods.xcodeproj"
          project = Xcodeproj::Project.open(path)
          wrapper_projects.push project
      end
      return (wrapper_projects + [pods_project])
  end
  
  def self.zabel_get_wrapper_project_paths(project)
    wrapper_projects = project.files.select{|file|file.last_known_file_type=="wrapper.pb-project"}
      wrapper_project_paths = []
      wrapper_projects.each do | wrapper_project_file |
          wrapper_project_file_path = wrapper_project_file.real_path.to_s
          wrapper_project_paths.push wrapper_project_file_path
      end
      return wrapper_project_paths.uniq
  end
  
  def self.zabel_can_cache_target(target)
      if target.name.start_with? "Pods-"
          return false
      end
      if target.class == Xcodeproj::Project::Object::PBXNativeTarget
          # see https://github.com/CocoaPods/Xcodeproj/blob/master/lib/xcodeproj/constants.rb#L145
          if target.product_type == "com.apple.product-type.bundle" or 
              target.product_type == "com.apple.product-type.library.static" or
              target.product_type == "com.apple.product-type.framework"
              return true
          end
      end
      return false
  end
  
  def self.zabel_get_dependency_files(target, intermediate_dir, product_dir, xcframeworks_build_dir)
      dependency_files = []
      Dir.glob("#{intermediate_dir}/**/*.d").each do | dependency_file |
          content = File.read(dependency_file)
          # see https://github.com/ccache/ccache/blob/master/src/Depfile.cpp#L141
          # and this is a simple regex parser enough to get all files, as far as I know.
          files = content.scan(/(?:\S(?:\\ )*)+/).flatten.uniq
          files = files - ["dependencies:", "\\", ":"]
  
          files.each do | file |
              file = file.gsub("\\ ", " ")
  
              unless File.exist? file
                  puts "[ZABEL]<ERROR> #{target.name} #{file} should exist in dependency file #{dependency_file}"
                  return []
              end
  
              if file.start_with? intermediate_dir + "/" or 
                  file.start_with? product_dir + "/" or
                  file.start_with? xcframeworks_build_dir + "/"
                  next
              end
  
              dependency_files.push file
          end
      end
      return dependency_files.uniq
  end
  
  def self.zabel_get_target_source_files(target)
      files = []
      target.source_build_phase.files.each do | file |
          file_path = file.file_ref.real_path.to_s
          files.push file_path
      end
      target.headers_build_phase.files.each do | file |
          file_path = file.file_ref.real_path.to_s
          files.push file_path
      end
      target.resources_build_phase.files.each do | file |
          file_path = file.file_ref.real_path.to_s
          files.push file_path
      end
      expand_files = []
      files.uniq.each do | file |
          next unless File.exist? file
          if File.file? file
              expand_files.push file
          else
              Find.find(file).each do | file_in_dir |
                  if File.file? file_in_dir
                      expand_files.push file_in_dir
                  end
              end
          end
      end
      return expand_files.uniq
  end
  
  def self.zabel_get_content_without_pwd(content)
      content = content.gsub("#{Dir.pwd}/", "").gsub(/#{Dir.pwd}(\W|$)/, '\1')
      return content
  end
  
  $zabel_file_md5_hash = {}
  
  def self.zabel_get_file_md5(file)
      if $zabel_file_md5_hash.has_key? file
          return $zabel_file_md5_hash[file]
      end
      md5 = Digest::MD5.hexdigest(File.read(file))
      $zabel_file_md5_hash[file] = md5
      return md5
  end

  def self.zabel_keep
      file_list = Dir.glob("#{zabel_get_cache_root}/*")
      file_time_hash = {}
      file_list.each do | file |
          file_time_hash[file] = File.mtime(file)
      end
      file_list = file_list.sort_by {|file| - file_time_hash[file].to_f}
      puts "[ZABEL]<INFO> keep cache " + file_list.size.to_s + " " + Open3.capture3("du -sh #{zabel_get_cache_root}")[0].to_s
  
      if file_list.size > 1
          puts "[ZABEL]<INFO> keep oldest " + file_time_hash[file_list.last].to_s + " " + file_list.last
          puts "[ZABEL]<INFO> keep newest " + file_time_hash[file_list.first].to_s + " " + file_list.first
      end
  
      if file_list.size > zabel_get_cache_count
          file_list_remove = file_list[zabel_get_cache_count..(file_list.size-1)]
          file_list_remove.each do | file |
              raise unless system "rm -rf \"#{file}\""
          end
      end
  end
  
  def self.zabel_clean_backup_project(project)
      command = "rm -rf \"#{project.path}/project.zabel_backup_pbxproj\""
      raise unless system command
  end
  
  
  def self.zabel_backup_project(project)
      command = "cp \"#{project.path}/project.pbxproj\" \"#{project.path}/project.zabel_backup_pbxproj\""
      raise unless system command
  end
  
  def self.zabel_restore_project(project)
      if File.exist? "#{project.path}/project.zabel_backup_pbxproj"
          command = "mv \"#{project.path}/project.zabel_backup_pbxproj\" \"#{project.path}/project.pbxproj\""
          raise unless system command
      end
  end
  
  $zabel_podfile_spec_checksums = nil
  
  def self.zabel_get_target_md5_content(project, target, configuration_name, argv, source_files)
  
      unless $zabel_podfile_spec_checksums
          if File.exist? "Podfile.lock"
              podfile_lock = YAML.load(File.read("Podfile.lock"))
              $zabel_podfile_spec_checksums = podfile_lock["SPEC CHECKSUMS"]
          end
      end
  
      project_configuration = project.build_configurations.detect { | config | config.name == configuration_name}
      project_configuration_content = project_configuration.pretty_print.to_yaml
      project_xcconfig = ""
      if project_configuration.base_configuration_reference
          config_file_path = project_configuration.base_configuration_reference.real_path
          if File.exist? config_file_path
              project_xcconfig = File.read(config_file_path).lines.reject{|line|line.include? "_SEARCH_PATHS"}.sort.join("")
          end
      end
  
      target_configuration = target.build_configurations.detect { | config | config.name == configuration_name}
      target_configuration_content = target_configuration.pretty_print.to_yaml
      target_xcconfig = ""
      if target_configuration.base_configuration_reference
          config_file_path = target_configuration.base_configuration_reference.real_path
          if File.exist? config_file_path
              target_xcconfig = File.read(config_file_path).lines.reject{|line|line.include? "_SEARCH_PATHS"}.sort.join("")
          end
      end
  
      first_configuration = []
      build_phases = []
      build_phases.push target.source_build_phase if target.methods.include? :source_build_phase
      build_phases.push target.resources_build_phase if target.methods.include? :resources_build_phase
      build_phases.each do | build_phase |
          target.source_build_phase.files_references.each do | files_reference |
              files_reference.build_files.each do |build_file|
                  if build_file.settings and build_file.settings.class == Hash
                      first_configuration.push File.basename(build_file.file_ref.real_path.to_s) + "\n" + build_file.settings.to_yaml
                  end
              end
          end
      end
      first_configuration_content = first_configuration.sort.uniq.join("\n")
  
      key_argv = []
  
      # TODO: to add more and test more
      # However, you can control your cache keys manually by using pre and post.
      temp_path_list = ["-derivedDataPath", "-archivePath", "-exportPath", "-packageCachePath"]
      argv.each_with_index do | arg, index |
          next if temp_path_list.include? arg
          next if index > 0 and temp_path_list.include? argv[index-1]
          next if arg.start_with? "DSTROOT="
          next if arg.start_with? "OBJROOT="
          next if arg.start_with? "SYMROOT="
          key_argv.push arg
      end
  
      source_md5_list = []
       # zabel built-in verison, which will be changed for incompatibility in the future
      source_md5_list.push "Version : #{Zabel::VERSION}"
      source_md5_list.push "ARGV : #{key_argv.to_s}"
  
      has_found_checksum = false
      split_parts = target.name.split("-")
      split_parts.each_with_index do | part, index |
          spec_name = split_parts[0..index].join("-")
          # TODO: to get a explicit spec name from a target. 
          # Now all potential spec names are push into md5 for safety.
          if $zabel_podfile_spec_checksums.has_key? spec_name
              source_md5_list.push "SPEC CHECKSUM : #{spec_name} #{$zabel_podfile_spec_checksums[spec_name]}"
              has_found_checksum = true
          end
      end
      unless has_found_checksum
          puts "[ZABEL]<ERROR> #{target.name} SPEC CHECKSUM should be found"
      end
  
      source_md5_list.push "Project : #{File.basename(project.path)}"
      source_md5_list.push "Project configuration : "
      source_md5_list.push project_configuration_content.strip
      source_md5_list.push "Project xcconfig : "
      source_md5_list.push project_xcconfig.strip
      source_md5_list.push "Target : #{target.name}"
      source_md5_list.push "Target type : #{target.product_type}"
      source_md5_list.push "Target configuration : "
      source_md5_list.push target_configuration_content.strip
      source_md5_list.push "Target xcconfig : "
      source_md5_list.push target_xcconfig.strip
      source_md5_list.push "Files settings : "
      source_md5_list.push first_configuration_content.strip
      
      source_md5_list.push "Files MD5 : "
      source_files.uniq.sort.each do | file |
          source_md5_list.push zabel_get_content_without_pwd(file) + " : " + zabel_get_file_md5(file)
      end
  
      source_md5_content = source_md5_list.join("\n")
      return source_md5_content
  end
  
  def self.zabel_clean_temp_files
      command = "rm -rf Pods/*.xcodeproj/project.zabel_backup_pbxproj"
      puts command
      raise unless system command
  
      command = "rm -rf Pods/*.xcodeproj/*.#{FILE_NAME_TARGET_CONTEXT}"
      puts command
      raise unless system command
  
      command = "rm -rf Pods/zabel.xcodeproj"
      puts command
      raise unless system command
  end
  
  def self.zabel_add_cache(target, target_context, message)
      target_md5 = target_context[:target_md5]
  
      product_dir = target_context[BUILD_KEY_TARGET_BUILD_DIR]
      intermediate_dir = target_context[BUILD_KEY_TARGET_TEMP_DIR]
      wrapper_name = target_context[BUILD_KEY_WRAPPER_NAME]
  
      target_cache_dir = zabel_get_cache_root + "/" + target.name + "-" + target_md5 + "-" + (Time.now.to_f * 1000).to_i.to_s
  
      Dir.glob("#{product_dir}/**/*.modulemap").each do | modulemap |
          modulemap_content = File.read(modulemap)
          if modulemap_content.include? File.dirname(modulemap) + "/"
              modulemap_content = modulemap_content.gsub(File.dirname(modulemap) + "/", "")
              File.write(modulemap, modulemap_content)
          end
      end
  
      if target.product_type == "com.apple.product-type.library.static"
          find_result = Open3.capture3("find #{product_dir}/*.a -maxdepth 0")
          unless find_result[2] == 0 and find_result[0].lines.size == 1
              puts "[ZABEL]<ERROR> #{target.name} #{product_dir}/*.a should exist"
              return false
          end
      elsif target.product_type == "com.apple.product-type.bundle" or target.product_type == "com.apple.product-type.framework"
          unless wrapper_name and wrapper_name.size > 0 and File.exist? "#{product_dir}/#{wrapper_name}"
              puts "[ZABEL]<ERROR> #{target.name} #{product_dir}/#{wrapper_name} should exist"
              return false
          end
      end
  
      zip_start_time = Time.now
  
      command = "cd \"#{File.dirname(product_dir)}\" && tar -cf #{target.name}.#{FILE_NAME_PRODUCT} #{File.basename(product_dir)}"
      if target.product_type == "com.apple.product-type.library.static"
          command = "cd \"#{File.dirname(product_dir)}\" && tar --exclude=*.bundle -cf #{target.name}.#{FILE_NAME_PRODUCT} #{File.basename(product_dir)}"
      elsif target.product_type == 'com.apple.product-type.bundle'
          if wrapper_name and wrapper_name.size > 0
              command = "cd \"#{File.dirname(product_dir)}\" && tar -cf #{target.name}.#{FILE_NAME_PRODUCT} #{File.basename(product_dir)}/#{wrapper_name}"
          else
              puts "[ZABEL]<ERROR> #{target.name} WRAPPER_NAME should be found"
              return false
          end
      end
  
      puts command
      unless system command
          puts "[ZABEL]<ERROR> #{command} should succeed"
          return false
      end
  
      if File.exist? target_cache_dir
          puts "[ZABEL]<ERROR> #{target_cache_dir} should not exist"
          raise unless system "rm -rf \"#{target_cache_dir}\""
          return false
      end
  
      command = "mkdir -p \"#{target_cache_dir}\""
      unless system command
          puts command
          puts "[ZABEL]<ERROR> #{command} should succeed"
          return false
      end
  
      cache_product_path = target_cache_dir + "/#{FILE_NAME_PRODUCT}"
  
      command = "mv \"#{File.dirname(product_dir)}/#{target.name}.#{FILE_NAME_PRODUCT}\" \"#{cache_product_path}\""
      puts command
      unless system command
          puts command
          puts "[ZABEL]<ERROR> #{command} should succeed"
          return false
      end
      unless File.exist? cache_product_path
          puts "[ZABEL]<ERROR> #{cache_product_path} should exist after mv"
          return false
      end
      
      target_context[:product_md5] = zabel_get_file_md5(cache_product_path)
      target_context[:target_build_dir_name] = target_context[BUILD_KEY_TARGET_BUILD_DIR].gsub(target_context[BUILD_KEY_SYMROOT] + "/", "")
      target_context[:target_temp_dir_name] = target_context[BUILD_KEY_TARGET_TEMP_DIR].gsub(target_context[BUILD_KEY_OBJROOT] + "/", "")
      if target_context[BUILD_KEY_MODULEMAP_FILE]
          target_context[BUILD_KEY_MODULEMAP_FILE] = zabel_get_content_without_pwd target_context[BUILD_KEY_MODULEMAP_FILE]
      end

      target_context = target_context.clone
      target_context.delete(:dependency_files)
      target_context.delete(:target_status)
      target_context.delete(:potential_hit_target_cache_dirs)
      target_context.delete(:target_md5_content)
      [BUILD_KEY_SYMROOT, BUILD_KEY_TARGET_BUILD_DIR, BUILD_KEY_OBJROOT, BUILD_KEY_TARGET_TEMP_DIR, BUILD_KEY_PODS_XCFRAMEWORKS_BUILD_DIR, BUILD_KEY_SRCROOT].each do | key |
          target_context.delete(key)
      end
  
      File.write(target_cache_dir + "/" + FILE_NAME_CONTEXT, target_context.to_yaml)
      File.write(target_cache_dir + "/" + FILE_NAME_MESSAGE, message)
  
      return true
  end
  
  def self.zabel_post(argv)
  
      unless argv.index("-configuration")
          raise "[ZABEL]<ERROR> -configuration should be set"
      end
      configuration_name = argv[argv.index("-configuration") + 1]

      start_time = Time.now
  
      add_count = 0
  
      projects = zabel_get_projects
  
      post_targets_context = {}
  
      projects.each do | project |
          project.native_targets.each do | target |
              if zabel_can_cache_target(target)
                  
                  target_context_file = "#{project.path}/#{target.name}.#{FILE_NAME_TARGET_CONTEXT}"
                  unless File.exist? target_context_file
                      next
                  end
                  
                  target_context = YAML.load(File.read(target_context_file))
              
                  if target_context[:target_status] == STATUS_MISS
                      source_files = zabel_get_target_source_files(target)
  
                      product_dir = target_context[BUILD_KEY_TARGET_BUILD_DIR]
                      intermediate_dir = target_context[BUILD_KEY_TARGET_TEMP_DIR]
                      xcframeworks_build_dir = target_context[BUILD_KEY_PODS_XCFRAMEWORKS_BUILD_DIR]
                      
                      dependency_files = zabel_get_dependency_files(target, intermediate_dir, product_dir, xcframeworks_build_dir)
                      if source_files.size > 0 and dependency_files.size == 0 and target.product_type != "com.apple.product-type.bundle"
                          puts "[ZABEL]<ERROR> #{target.name} should have dependent files"
                          next
                      end
                      target_context[:dependency_files] = dependency_files - source_files
                      target_md5_content = zabel_get_target_md5_content(project, target, configuration_name, argv, source_files)
                      target_context[:target_md5_content] = target_md5_content
                      target_md5 = Digest::MD5.hexdigest(target_md5_content)
                      unless target_context[:target_md5] == target_md5
                          puts "[ZABEL]<ERROR> #{target.name} md5 should not be changed after build"
                          next
                      end
                      if target_context[BUILD_KEY_SRCROOT] and target_context[BUILD_KEY_SRCROOT].size > 0 and 
                          target_context[BUILD_KEY_MODULEMAP_FILE] and target_context[BUILD_KEY_MODULEMAP_FILE].size > 0
                          if File.exist? Dir.pwd + "/" + zabel_get_content_without_pwd("#{target_context[BUILD_KEY_SRCROOT]}/#{target_context[BUILD_KEY_MODULEMAP_FILE]}")
                              target_context[BUILD_KEY_MODULEMAP_FILE] = zabel_get_content_without_pwd("#{target_context[BUILD_KEY_SRCROOT]}/#{target_context[BUILD_KEY_MODULEMAP_FILE]}")
                          else
                              puts "[ZABEL]<ERROR> #{target.name} #{target_context[BUILD_KEY_MODULEMAP_FILE]} should be supported"
                              next
                          end
                      end
                  elsif target_context[:target_status] == STATUS_HIT
                      if target_context[BUILD_KEY_MODULEMAP_FILE] and target_context[BUILD_KEY_MODULEMAP_FILE].size > 0
                          if not File.exist? Dir.pwd + "/" + target_context[BUILD_KEY_MODULEMAP_FILE]
                              puts "[ZABEL]<ERROR> #{target.name} #{target_context[BUILD_KEY_MODULEMAP_FILE]} should be supported"
                              next
                          end
                      end
                  else
                      puts "[ZABEL]<ERROR> #{target.name} should be hit or miss"
                      next
                  end
  
                  post_targets_context[target] = target_context
              end
          end
      end
  
      projects.each do | project |
          project.native_targets.each do | target |
              if post_targets_context.has_key? target
                  target_context = post_targets_context[target]
                  next unless target_context[:target_status] == STATUS_MISS
  
                  dependency_targets_set = Set.new
                  implicit_dependencies = []
                  
                  post_targets_context.each do | other_target, other_target_context |
                      next if other_target == target
  
                      next if target.product_type == "com.apple.product-type.bundle"
                      next if other_target.product_type == "com.apple.product-type.bundle"
  
                      target_context[:dependency_files].each do | dependency |
                          
                          if other_target_context[BUILD_KEY_TARGET_BUILD_DIR] and other_target_context[BUILD_KEY_TARGET_BUILD_DIR].size > 0 and
                              dependency.start_with? other_target_context[BUILD_KEY_TARGET_BUILD_DIR] + "/" 
                              dependency_targets_set.add other_target
                              implicit_dependencies.push dependency
                          elsif other_target_context[BUILD_KEY_TARGET_TEMP_DIR] and other_target_context[BUILD_KEY_TARGET_TEMP_DIR].size > 0 and
                              dependency.start_with? other_target_context[BUILD_KEY_TARGET_TEMP_DIR] + "/"
                              dependency_targets_set.add other_target
                              implicit_dependencies.push dependency
                          elsif other_target_context[:target_build_dir_name] and other_target_context[:target_build_dir_name].size > 0 and
                              dependency.start_with? target_context[BUILD_KEY_SYMROOT] + "/" + other_target_context[:target_build_dir_name] + "/" 
                              dependency_targets_set.add other_target
                              implicit_dependencies.push dependency
                          elsif other_target_context[:target_temp_dir_name] and other_target_context[:target_temp_dir_name].size > 0 and
                              dependency.start_with? target_context[BUILD_KEY_OBJROOT] + "/" + other_target_context[:target_temp_dir_name] + "/" 
                              dependency_targets_set.add other_target
                              implicit_dependencies.push dependency
                          end
  
                          unless zabel_should_not_detect_module_map_dependency
                              if other_target_context[BUILD_KEY_MODULEMAP_FILE] and other_target_context[BUILD_KEY_MODULEMAP_FILE].size > 0 and
                                  dependency == Dir.pwd + "/" + other_target_context[BUILD_KEY_MODULEMAP_FILE]
                                  dependency_targets_set.add other_target
                              end
                          end
                      end
  
                      target_context[:dependency_files] = target_context[:dependency_files] - implicit_dependencies
  
                  end
  
                  target_context[:dependency_files] = target_context[:dependency_files] - implicit_dependencies
                  dependency_files_md5 = []
                  target_context[:dependency_files].each do | file |
                      dependency_files_md5.push [zabel_get_content_without_pwd(file), zabel_get_file_md5(file)]
                  end
                  target_context[:dependency_files_md5] = dependency_files_md5.sort.uniq
  
                  dependency_targets_md5 = dependency_targets_set.to_a.map { | target |  [target.name, post_targets_context[target][:target_md5]]}
                  target_context[:dependency_targets_md5] = dependency_targets_md5
      
                  message = target_context[:target_md5_content]
  
                  if zabel_add_cache(target, target_context, message)
                      add_count = add_count + 1
                  end
              end
          end
      end
  
      projects.each do | project |
          zabel_restore_project(project)
      end
  
      zabel_keep
  
      puts "[ZABEL]<INFO> total add #{add_count}"
  
      puts "[ZABEL]<INFO> duration = #{(Time.now - start_time).to_i} s in stage post"
  
  end
  
  def self.zabel_get_potential_hit_target_cache_dirs(target, target_md5)
      dependency_start_time = Time.now
      target_cache_dirs = Dir.glob(zabel_get_cache_root + "/" + target.name + "-" + target_md5 + "-*")
      file_time_hash = {}
      target_cache_dirs.each do | file |
          file_time_hash[file] = File.mtime(file)
      end
      target_cache_dirs = target_cache_dirs.sort_by {|file| - file_time_hash[file].to_f}
      potential_hit_target_cache_dirs = []
      target_cache_dirs.each do | target_cache_dir |
          next unless File.exist? target_cache_dir + "/" + FILE_NAME_PRODUCT
          next unless File.exist? target_cache_dir + "/" + FILE_NAME_CONTEXT
          target_context = YAML.load(File.read(target_cache_dir + "/" + FILE_NAME_CONTEXT))
          dependency_miss = false
          target_context[:dependency_files_md5].each do | item |
              dependency_file = item[0]
              dependency_md5 = item[1]
  
              unless File.exist? dependency_file
                  puts "[ZABEL]<WARNING> #{target.name} #{dependency_file} file should exist to be hit"
                  dependency_miss = true
                  break
              end
              unless zabel_get_file_md5(dependency_file) == dependency_md5
                  puts "[ZABEL]<WARNING> #{target.name} #{dependency_file} md5 should match to be hit"
                  dependency_miss = true
                  break
              end
          end
          if not dependency_miss
              if not target_context[:target_md5] == target_md5
                  command = "rm -rf \"#{target_cache_dir}\""
                  raise unless system command
                  puts "[ZABEL]<ERROR> #{target.name} #{target_cache_dir} target md5 should match to be verified"
                  dependency_miss = false
                  next
              end
              if not target_context[:product_md5] == zabel_get_file_md5(target_cache_dir + "/" + FILE_NAME_PRODUCT)
                  command = "rm -rf \"#{target_cache_dir}\""
                  raise unless system command
                  puts "[ZABEL]<ERROR> #{target.name} #{target_cache_dir} product md5 should match to be verified"
                  dependency_miss = false
                  next
              end
  
              potential_hit_target_cache_dirs.push target_cache_dir
              if target_context[:dependency_targets_md5].size == 0
                  break
              end
              if potential_hit_target_cache_dirs.size > 10
                  break
              end
          end
      end
      return potential_hit_target_cache_dirs
  end
  
  # see https://github.com/CocoaPods/Xcodeproj/blob/master/lib/xcodeproj/project/object/native_target.rb#L239
  # and this is faster, without searching deeply. 
  def self.zabel_fast_add_dependency(project, target_target, target, subproject_reference)
      container_proxy = project.new(Xcodeproj::Project::PBXContainerItemProxy)
      container_proxy.container_portal = subproject_reference.uuid
      container_proxy.proxy_type = Xcodeproj::Constants::PROXY_TYPES[:native_target]
      container_proxy.remote_global_id_string = target.uuid
      container_proxy.remote_info = target.name
  
      dependency = project.new(Xcodeproj::Project::PBXTargetDependency)
      dependency.name = target.name
      dependency.target_proxy = container_proxy
  
      target_target.dependencies << dependency
  end
  
  def self.zabel_disable_build_and_inject_extract(project, target, inject_project, inject_target, inject_scripts, target_context)
      target_cache_dir = target_context[:hit_target_cache_dir]

      # touch to update mtime
      raise unless system "touch \"#{target_cache_dir}\""
  
      # delete build phases to disable build command
      target.build_phases.delete_if { | build_phase | 
          build_phase.class == Xcodeproj::Project::Object::PBXHeadersBuildPhase or 
          build_phase.class == Xcodeproj::Project::Object::PBXSourcesBuildPhase or 
          build_phase.class == Xcodeproj::Project::Object::PBXResourcesBuildPhase
      }

      extract_script = "zabel #{STAGE_EXTRACT} \"#{target_cache_dir}\" \"#{target_context[:target_build_dir_name]}\" \"#{target_context[:target_temp_dir_name]}\""

      if zabel_should_extract_once
          subproject_reference = nil
          project.main_group.files.each do | file |
              if file.class == Xcodeproj::Project::Object::PBXFileReference and File.basename(file.path) == File.basename(inject_project.path)
                  subproject_reference = file
                  break
              end
          end
      
          unless subproject_reference
              subproject_reference = project.main_group.new_reference(inject_project.path, :group)
          end
      
          zabel_fast_add_dependency(project, target, inject_target, subproject_reference)
          
          inject_scripts.push extract_script
      else
          inject_phase = target.new_shell_script_build_phase("zabel_extract_#{target.name}")
          inject_phase.shell_script = extract_script
          inject_phase.show_env_vars_in_log = '0'
      end
  end
  
  def self.zabel_inject_printenv(project, target)
      inject_phase = target.new_shell_script_build_phase("zabel_printenv_#{target.name}")
      inject_phase.shell_script = "zabel #{STAGE_PRINTENV} #{target.name} \"#{project.path}\""
      inject_phase.show_env_vars_in_log = '0'
  end
  
  def self.zabel_pre(argv)
  
      unless argv.index("-configuration")
          raise "[ZABEL]<ERROR> -configuration should be set"
      end
      configuration_name = argv[argv.index("-configuration") + 1]

      start_time = Time.now
  
      if ENV["ZABEL_CLEAR_ALL"] == "YES"
          command = "rm -rf \"#{zabel_get_cache_root}\""
          puts command
          raise unless system command
      end
  
      zabel_clean_temp_files
  
      if zabel_should_extract_once
          inject_project = Xcodeproj::Project.new("Pods/zabel.xcodeproj")
          inject_target = inject_project.new_aggregate_target("zabel")
          inject_phase = inject_target.new_shell_script_build_phase("zabel_extract")
          inject_phase.show_env_vars_in_log = '0'
          inject_project.save
          inject_scripts = []
      end
  
      projects = zabel_get_projects
  
      pre_targets_context = {}
  
      hit_count = 0
      miss_count = 0
      hit_target_md5_cache_set = Set.new
      iteration_count = 0
  
      projects.each do | project |
          project.native_targets.each do | target |
              if zabel_can_cache_target(target)
                  source_files = zabel_get_target_source_files(target)
                  next unless source_files.size >= zabel_get_min_source_file_count
                  target_md5_content = zabel_get_target_md5_content(project, target, configuration_name, argv, source_files)
                  target_md5 = Digest::MD5.hexdigest(target_md5_content)
                  potential_hit_target_cache_dirs = zabel_get_potential_hit_target_cache_dirs(target, target_md5) 
  
                  target_context = {}
                  target_context[:target_md5] = target_md5
                  target_context[:potential_hit_target_cache_dirs] = potential_hit_target_cache_dirs
                  if potential_hit_target_cache_dirs.size == 0
                      puts "[ZABEL]<INFO> miss #{target.name} #{target_md5} in iteration #{iteration_count}"
                      target_context[:target_status] = STATUS_MISS
                      miss_count = miss_count + 1
                  end
                  pre_targets_context[target] = target_context
              end
          end
      end
  
      while true
          iteration_count = iteration_count + 1
          confirm_count = hit_count + miss_count
          projects.each do | project |
              project.native_targets.each do | target |
                  next unless pre_targets_context.has_key? target
                  target_context = pre_targets_context[target]
                  next if target_context[:target_status] == STATUS_MISS
                  next if target_context[:target_status] == STATUS_HIT
                  potential_hit_target_cache_dirs = target_context[:potential_hit_target_cache_dirs]
                  next if potential_hit_target_cache_dirs.size == 0
  
                  hit_target_cache_dir = nil
                  potential_hit_target_cache_dirs.each do | target_cache_dir |
                      next unless File.exist? target_cache_dir + "/" + FILE_NAME_CONTEXT
                      hit_target_context = YAML.load(File.read(target_cache_dir + "/" + FILE_NAME_CONTEXT))
                      hit_target_cache_dir = target_cache_dir
                      hit_target_context[:dependency_targets_md5].each do | item |
                          dependency_target = item[0]
                          dependency_target_md5 = item[1]
                          
                          # cycle dependency targets will be miss every time. 
                          # TODO: to detect cycle dependency so that cache will not be added,
                          # or to hit cache together with some kind of algorithms.
                          unless hit_target_md5_cache_set.include? "#{dependency_target}-#{dependency_target_md5}"
                              hit_target_cache_dir = nil
                              break
                          end
                      end
                      if hit_target_cache_dir
                          target_context = target_context.merge!(hit_target_context)
                          break
                      end
                  end
                  if hit_target_cache_dir
                      puts "[ZABEL]<INFO> hit #{target.name} #{target_context[:target_md5]} in iteration #{iteration_count} potential #{potential_hit_target_cache_dirs.size}"
                      target_context[:target_status] = STATUS_HIT
                      target_context[:hit_target_cache_dir] = hit_target_cache_dir
                      hit_count = hit_count + 1
                      hit_target_md5_cache_set.add "#{target.name}-#{target_context[:target_md5]}"
                  end
              end
          end
          if hit_count + miss_count == confirm_count
              break
          end
      end
  
      projects.each do | project |
          should_save = false
          project.native_targets.each do | target |
              next unless pre_targets_context.has_key? target
              target_context = pre_targets_context[target]
  
              if target_context[:target_status] == STATUS_HIT
                  zabel_disable_build_and_inject_extract(project, target, inject_project, inject_target, inject_scripts, target_context)
              else
                  unless target_context[:target_status] == STATUS_MISS
                      target_context[:target_status] = STATUS_MISS
                      puts "[ZABEL]<INFO> miss #{target.name} #{target_context[:target_md5]} in iteration #{iteration_count}"
                      miss_count = miss_count + 1
                  end
                  zabel_inject_printenv(project, target)
              end
              File.write("#{project.path}/#{target.name}.#{FILE_NAME_TARGET_CONTEXT}", target_context.to_yaml)

              should_save = true
          end

          if should_save
              zabel_backup_project(project)
              project.save
          else
              zabel_clean_backup_project(project)
          end
      end
  
      if zabel_should_extract_once and inject_scripts.size > 0
          inject_scripts = (["startTime_s=`date +%s`"] + inject_scripts + ["echo \"[ZABEL]<INFO> duration = $[ `date +%s` - $startTime_s ] s in stage #{STAGE_EXTRACT}\""]).flatten
          inject_phase.shell_script = inject_scripts.join("\n")
          inject_project.save
      end

      puts "[ZABEL]<INFO> total #{hit_count + miss_count} hit #{hit_count} miss #{miss_count} iteration #{iteration_count}"
  
      puts "[ZABEL]<INFO> duration = #{(Time.now - start_time).to_i} s in stage pre"
  end
  
  def self.zabel_extract
      target_cache_dir = ARGV[1]
      product_path = ARGV[2]
      intermediate_path = ARGV[3]
      
      cache_product_path = target_cache_dir + "/#{FILE_NAME_PRODUCT}"
  
      start_time = Time.now
      command = "mkdir -p \"#{ENV[BUILD_KEY_SYMROOT]}/#{product_path}\" && cd \"#{ENV[BUILD_KEY_SYMROOT]}/#{product_path}/..\" && tar -xf \"#{cache_product_path}\""
      puts command
      raise unless system command
  
  end
  
  def self.zabel_printenv
      target_name = ARGV[1]
      project_path = ARGV[2]
      
      target_context = YAML.load(File.read("#{project_path}/#{target_name}.#{FILE_NAME_TARGET_CONTEXT}"))
  
      # see https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/XcodeBuildSettingRef/1-Build_Setting_Reference/build_setting_ref.html
      [BUILD_KEY_SYMROOT, BUILD_KEY_TARGET_BUILD_DIR, BUILD_KEY_OBJROOT, BUILD_KEY_TARGET_TEMP_DIR, BUILD_KEY_PODS_XCFRAMEWORKS_BUILD_DIR, BUILD_KEY_MODULEMAP_FILE, BUILD_KEY_SRCROOT, BUILD_KEY_WRAPPER_NAME].sort.each do | key |
          if ENV[key]
              target_context[key] = ENV[key]
          end
      end
      File.write("#{project_path}/#{target_name}.#{FILE_NAME_TARGET_CONTEXT}", target_context.to_yaml)
  end
  
  def self.zabel_clean
      if File.exist? "Pods/zabel.xcodeproj"
          command = "rm -rf Pods/*.xcodeproj"
          puts command
          raise unless system command
      end
      zabel_clean_temp_files
  end

end
