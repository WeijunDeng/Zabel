require 'pathname'
require 'open3'
require 'yaml'

def system_cmd(cmd)
    puts cmd
    start_time = Time.now
    if cmd.start_with? "rm -rf "
        while not system cmd
            puts cmd
        end
    end

    unless system cmd
        raise "command should not fail"
    end
    puts "duration = #{Time.now - start_time}" if (Time.now - start_time).to_f > 1
end

def zabel_test_cache_option(cache_option, cache_root)
    if cache_option.start_with? "cache"
        if cache_option == "cache_clear"
            system_cmd "rm -rf \"#{cache_root}\""
        elsif cache_option == "cache_remove_half"
            cache_list = Dir.glob("#{cache_root}/*")
            origin_cache_count = cache_list.size
            cache_list.shuffle[0..((cache_list.size-1)/2)].each do | target_cache_dir |
                system_cmd "rm -rf \"#{target_cache_dir}\""
            end
            puts "current cache count #{Dir.glob("#{cache_root}/*").size} / #{origin_cache_count}"
        elsif cache_option == "cache_remove_dependency"
            cache_list = Dir.glob("#{cache_root}/*")
            origin_cache_count = cache_list.size
            cache_list.shuffle.each do | target_cache_dir |
                next unless File.exist? target_cache_dir + "/context.yml"
                target_context = YAML.load(File.read(target_cache_dir + "/context.yml"))
                if target_context[:dependency_targets_md5].size > 0
                    system_cmd "rm -rf \"#{target_cache_dir}\""
                end
            end
            puts "current cache count #{Dir.glob("#{cache_root}/*").size} / #{origin_cache_count}"
        elsif cache_option == "cache_remove_having_dependency"
            cache_list = Dir.glob("#{cache_root}/*")
            origin_cache_count = cache_list.size
            cache_list.shuffle.each do | target_cache_dir |
                next unless File.exist? target_cache_dir + "/context.yml"
                target_context = YAML.load(File.read(target_cache_dir + "/context.yml"))
                target_context[:dependency_targets_md5].each do | dependency_targets_md5 |
                    system_cmd "rm -rf \"#{cache_root}/#{dependency_targets_md5[0]}-#{dependency_targets_md5[1]}\"*"
                end
            end
            puts "current cache count #{Dir.glob("#{cache_root}/*").size} / #{origin_cache_count}"
        end
    end
end

def zabel_test(podfiles)

    cache_root = Dir.pwd + "/cache"
    system_cmd "rm -rf \"#{cache_root}\""

    all_build_options = ["xcodebuild", "fastlane"].product(["", "archive"], ["", "derived_data_path"]).map{|options| options.select{|option|option.size>0}.join(",")}

    all_pod_options = ["", "use_modular_headers"].product(["", "generate_multiple_pod_projects"], ["", "precompile_prefix_header"], ["", "use_frameworks_static", "use_frameworks_dynamic"]).map{|options| options.select{|option|option.size>0}.join(",")}

    all_cache_options = ["cache_all1", "cache_all2", "cache_remove_dependency", "cache_remove_having_dependency", "cache_remove_half", "cache_remove_half"]

    test_count = 0

    all_build_options.shuffle.each do | build_option |
        all_pod_options.shuffle.each do | pod_option |
            podfiles.shuffle.each do | podfile |
                
                system_cmd "rm -rf #{Dir.pwd + "/tmp/*/Pods"}"
                system_cmd "rm -rf #{Dir.pwd + "/tmp/*/build-*"}"
                system_cmd "rm -rf ~/Library/Developer/Xcode/DerivedData"
                
                first_size = 0
                all_cache_options.each do | cache_option |
                    test_count = test_count + 1
                    timestamp = (Time.now.to_f * 1000).to_i.to_s
                    workspace = Dir.pwd + "/tmp/" + timestamp

                    puts "test_count = #{test_count}"
                    puts [build_option, pod_option, cache_option, podfile].join("  ")
                    
                    system_cmd "mkdir -p \"#{workspace}\""
                    system_cmd "cp \"#{podfile}\" \"#{workspace}\""
                    system_cmd "rm -rf \"#{workspace}/Pods\""
                    system_cmd "cd \"#{workspace}\" && export ZABEL_TEST_POD_OPTIONS=#{pod_option} && pod update --no-repo-update --silent"

                    File.write(workspace + "/options-#{timestamp}.txt", [build_option, pod_option, cache_option].join("\n"))

                    zabel_test_cache_option(cache_option, cache_root)
                    
                    prefix = ""
                    if cache_option.start_with? "cache"
                        prefix = "zabel"
                    end

                    log_path = "#{workspace}/log-#{timestamp}.log"
                    build_path = "#{workspace}/build-#{timestamp}"
                    app_path = "#{build_path}/Build/Products/Debug-iphonesimulator/app.app"
                    if build_option.include? "archive"
                        app_path = "#{build_path}/app.xcarchive/Products/Applications/app.app"
                    end
                    system_cmd "rm -rf \"#{build_path}\""
                    if build_option.include? "xcodebuild"
                        derived_data_path = ""
                        if build_option.include? "derived_data_path"
                            derived_data_path = "-derivedDataPath \"#{build_path}\""
                        end
                        archive_path = ""
                        build = "clean build"
                        if build_option.include? "archive"
                            archive_path = "-archivePath \"#{build_path}/app.xcarchive\""
                            build = "archive"
                        end
                        
                        system_cmd "cd \"#{workspace}\" && export ZABEL_CACHE_ROOT=\"#{cache_root}\" && #{prefix} xcodebuild #{build} -workspace app.xcworkspace -scheme app -configuration Debug -arch x86_64 -sdk iphonesimulator #{derived_data_path} #{archive_path} &> \"#{log_path}\""
                    elsif build_option.include? "fastlane"
                        derived_data_path = ""
                        if build_option.include? "derived_data_path"
                            derived_data_path = "--derived_data_path \"#{build_path}\""
                        end
                        archive_path = ""
                        skip_archive = "--skip_archive"
                        if build_option.include? "archive"
                            archive_path = "--archive_path \"#{build_path}/app.xcarchive\""
                            skip_archive = ""
                        end

                        system_cmd "cd \"#{workspace}\" && export ZABEL_CACHE_ROOT=\"#{cache_root}\" && export FASTLANE_DISABLE_COLORS=1 && #{prefix} fastlane gym --workspace app.xcworkspace --scheme app --configuration Debug --xcargs 'ARCHS=x86_64' --sdk iphonesimulator --destination 'generic/platform=iOS Simulator' --clean #{derived_data_path} #{archive_path} --skip_package_ipa --disable_xcpretty #{skip_archive} &> \"#{log_path}\""
                    end
            
                    if build_option.include? "archive" or build_option.include? "derived_data_path"
                        unless File.exist? app_path
                            raise "build app path should exist"
                        end
                    end
                    
                    log_content = File.read(log_path)
                    if build_option.include? "archive"
                        unless log_content.include? "** ARCHIVE SUCCEEDED **"
                            raise "build log should include ARCHIVE SUCCEEDED"
                        end
                    else
                        unless log_content.include? "** BUILD SUCCEEDED **"
                            raise "build log should include BUILD SUCCEEDED"
                        end
                    end
                    if log_content.include? "[ZABEL]<ERROR>"
                        raise "build log should not include [ZABEL]<ERROR>"
                    end

                    if cache_option == "cache_all2"
                        unless log_content.include? " miss 0 "
                            raise "build log should include miss 0"
                        end
                    end
                    
                    if build_option.include? "archive" or build_option.include? "derived_data_path"
                        if first_size == 0
                            first_size = Open3.capture3("du -s \"#{app_path}\"")[0].strip.to_i
                            puts first_size
                            unless first_size > 0
                                raise "build app size should not empty"
                            end
                        else
                            size = Open3.capture3("du -s \"#{app_path}\"")[0].strip.to_i
                            puts size
                            unless size == first_size
                                raise "build app size should equal to first"
                            end
                        end
                    end
            
                    dirty_files = []
                    Dir.glob("#{cache_root}/*").sort.each do | target_cache_dir |
                        file = target_cache_dir + "/context.yml"
                        next unless File.exist? file
                        if File.read(file).include? "#{timestamp}"
                            dirty_files.push file
                        end
                        file = target_cache_dir + "/message.txt"
                        next unless File.exist? file
                        if File.read(file).include? "#{timestamp}"
                            dirty_files.push file
                        end
                    end
                    if dirty_files.size > 0
                        puts dirty_files
                        raise "cache file should not contain path #{timestamp}"
                    end
                end
            end
        end
    end
end