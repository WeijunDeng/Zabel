require 'pathname'

current_file_path = Pathname.new(__FILE__).realpath.to_s
current_file_dir = File.dirname(current_file_path)

require current_file_dir + "/base.rb"

podfiles = Dir.glob("#{current_file_dir}/case/*/Podfile")

zabel_test podfiles
