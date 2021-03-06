require 'pathname'
require 'open3'
require 'yaml'
require 'json'

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

    all_build_options = ["xcodebuild", "fastlane"].product(["build_app", "archive_app", "build_library"], ["", "derived_data_path"], ["", "modern_build_system"]).map{|options|options.select{|option|option.size>0}.join(",")}

    all_pod_options = ["", "use_modular_headers"].product(["", "generate_multiple_pod_projects"], ["", "precompile_prefix_header"], ["", "use_frameworks_static", "use_frameworks_dynamic"]).map{|options| options.select{|option|option.size>0}.join(",")}

    all_cache_options = ["cache_all1", "cache_all2", "cache_remove_dependency", "cache_remove_having_dependency", "cache_remove_half", "cache_remove_half"]

    test_count = 0

    all_build_options.shuffle.each do | build_option |
        all_pod_options.shuffle.each do | pod_option |
            podfiles.shuffle.each do | podfile |
                
                system_cmd "rm -rf #{Dir.pwd + "/tmp/*/Pods"}"
                system_cmd "rm -rf #{Dir.pwd + "/tmp/*/build-*"}"
                system_cmd "rm -rf \"#{Dir.home}/Library/Developer/Xcode/DerivedData\""
                
                first_size = 0
                build_library_shceme = ""
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
                    app_suffix = "app.app"
                    if build_option.include? "build_library"
                        app_suffix = ""
                    end
                    app_path = "#{build_path}/Build/Products/Debug-iphonesimulator/#{app_suffix}"
                    if build_option.include? "archive"
                        app_path = "#{build_path}/app.xcarchive/Products/Applications/#{app_suffix}"
                    end
                    system_cmd "rm -rf \"#{build_path}\""
                    if build_option.include? "xcodebuild"
                        derived_data_path = ""
                        if build_option.include? "derived_data_path"
                            derived_data_path = "-derivedDataPath \"#{build_path}\""
                        end
                        modern_build_system = "-UseModernBuildSystem=NO"
                        if build_option.include? "modern_build_system"
                            modern_build_system = "-UseModernBuildSystem=YES"
                        end

                        archive_path = ""
                        build = "clean build"
                        scheme = "app"
                        if build_option.include? "archive_app"
                            archive_path = "-archivePath \"#{build_path}/app.xcarchive\""
                            build = "archive"
                        elsif build_option.include? "build_library"
                            unless build_library_shceme.size > 0
                                cmd = "cd \"#{workspace}\" && xcodebuild -workspace app.xcworkspace -list -json"
                                puts cmd
                                scheme_json_result = Open3.capture3(cmd)
                                raise "list scheme should not fail" unless scheme_json_result[2] == 0
                                
                                scheme_json = JSON.parse(scheme_json_result[0])
                                schemes = scheme_json["workspace"]["schemes"].select{|s|not s.start_with? "app" and not s.start_with? "Pods"}
                                puts schemes
                                build_library_shceme = schemes.shuffle[0]
                            end
                            scheme = build_library_shceme
                        elsif build_option.include? "build_app"
                        else
                            raise
                        end

                        system_cmd "cd \"#{workspace}\" && export ZABEL_CACHE_ROOT=\"#{cache_root}\" && #{prefix} xcodebuild #{build} -workspace app.xcworkspace -scheme #{scheme} -configuration Debug -arch x86_64 -sdk iphonesimulator #{derived_data_path} #{archive_path} #{modern_build_system} &> \"#{log_path}\""
                    elsif build_option.include? "fastlane"
                        derived_data_path = ""
                        if build_option.include? "derived_data_path"
                            derived_data_path = "--derived_data_path \"#{build_path}\""
                        end
                        archive_path = ""
                        skip_archive = "--skip_archive"
                        if build_option.include? "archive_app"
                            archive_path = "--archive_path \"#{build_path}/app.xcarchive\""
                            skip_archive = ""
                        elsif build_option.include? "build_app"
                        else
                            raise
                        end
                        modern_build_system = "-UseModernBuildSystem=NO"
                        if build_option.include? "modern_build_system"
                            modern_build_system = "-UseModernBuildSystem=YES"
                        end
                        system_cmd "cd \"#{workspace}\" && export ZABEL_CACHE_ROOT=\"#{cache_root}\" && export FASTLANE_DISABLE_COLORS=1 && #{prefix} fastlane gym --workspace app.xcworkspace --scheme app --configuration Debug --xcargs 'ARCHS=x86_64 #{modern_build_system}' --sdk iphonesimulator --destination 'generic/platform=iOS Simulator' --clean #{derived_data_path} #{archive_path} --skip_package_ipa --disable_xcpretty #{skip_archive} &> \"#{log_path}\""
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
                    if log_content.include? "[ZABEL/E]"
                        raise "build log should not include [ZABEL/E]"
                    end

                    if cache_option == "cache_all2" and not build_option.include? "build_library"
                        unless log_content.include? " miss 0 "
                            raise "build log should include miss 0"
                        end
                    end
                    
                    if build_option.include? "archive" or build_option.include? "derived_data_path"
                        if first_size == 0
                            first_size = Open3.capture3("du -s \"#{app_path}\"")[0].strip.to_i
                            unless first_size > 0
                                raise "build app size should not empty"
                            end
                        else
                            size = Open3.capture3("du -s \"#{app_path}\"")[0].strip.to_i
                            unless size == first_size
                                raise "build app size #{size} should equal to first #{first_size}"
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