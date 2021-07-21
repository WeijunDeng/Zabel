require 'pathname'
require 'open3'
require 'yaml'

def system_cmd(cmd)
    puts cmd
    start_time = Time.now
    unless system cmd
        raise "command should not fail"
    end
    puts "duration = #{Time.now - start_time}" if (Time.now - start_time).to_f > 1
end

workspace = File.dirname(Pathname.new(__FILE__).realpath.to_s)

zabel = "zabel"

log_count = 0

system_cmd "rm -rf \"#{workspace}/logs\""
system_cmd "mkdir -p \"#{workspace}/logs\""
system_cmd "rm -rf \"#{workspace}/build\"* || rm -rf \"#{workspace}/build\"*"

all_pod_options = ["", "use_modular_headers"].product(["", "generate_multiple_pod_projects"], ["", "precompile_prefix_header"], ["", "use_frameworks_static", "use_frameworks_dynamic"]).map{|pod_option| pod_option.select{|option|option.size>0}.join(",")}

all_pod_options.shuffle.each do | pod_option |
    first_size = 0
    ["cache_keep", "cache_keep"].each do | build_option |

        system_cmd "rm -rf \"#{workspace}/Pods\" || rm -rf \"#{workspace}/Pods\""
        system_cmd "cd \"#{workspace}\" && export ZABEL_TEST_POD_OPTIONS=#{pod_option} && pod update --no-repo-update --silent"

        prefix = ""
        if build_option.start_with? "cache"
            prefix = "\"#{zabel}\""
            if build_option == "cache_clear"
                system_cmd "rm -rf \"#{workspace}/cache\""
            end
            if build_option == "cache_half"
                cache_list = Dir.glob("#{workspace}/cache/*")
                cache_list.shuffle[0..((cache_list.size-1)/2)].each do | cache |
                    system_cmd "rm -rf \"#{cache}\""
                end
                puts "remove cache #{cache_list.shuffle[0..((cache_list.size-1)/2)].size} in #{cache_list.size}"
            end
        end

        log_count = log_count + 1
        build_key = "build-#{"%02d" % log_count}"

        log_path = "#{workspace}/logs/#{build_key}.log"
        app_path = "#{workspace}/#{build_key}/Build/Products/Debug-iphonesimulator/app.app"
        system_cmd "rm -rf \"#{workspace}/#{build_key}\""
        system_cmd "cd \"#{workspace}\" && export ZABEL_CACHE_ROOT=\"#{workspace}/cache\" && #{prefix} xcodebuild -workspace app.xcworkspace -scheme app -configuration Debug -arch x86_64 -sdk iphonesimulator -derivedDataPath #{build_key} -showBuildTimingSummary build &> \"#{log_path}\""

        unless File.exist? app_path
            raise "build app path should exist"
        end
        
        log_content = File.read(log_path)
        unless log_content.include? "** BUILD SUCCEEDED **"
            raise "build log should include BUILD SUCCEEDED"
        end
        if log_content.include? "[ZABEL]<ERROR>"
            raise "build log should not include [ZABEL]<ERROR>"
        end
        if log_content.include? "[ZABEL]<WARNING>"
            raise "build log should not include [ZABEL]<WARNING>"
        end
        
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
end