require 'pathname'

require File.dirname(Pathname.new(__FILE__).realpath.to_s) + "/base.rb"

zabel_test [ARGV[0]]