require 'pathname'

current_file_path = Pathname.new(__FILE__).realpath.to_s
current_file_dir = File.dirname(current_file_path)

tests = Dir.glob("#{current_file_dir}/case/*/test.rb").shuffle
puts "total tests #{tests.count}"

tests.each_with_index do | test, index |
    puts "---- #{index} #{test} ----"
    load test
end
