Pod::Spec.new do |s|
  s.name             = 'local-lib-swift'
  s.version          = '0.1.0'
  s.summary          = "https://dengweijun.com/"
  s.description      = "https://dengweijun.com/"
  s.homepage         = "https://dengweijun.com/"
  s.license          = ""
  s.author           = ""
  s.source           = { :http => 'https://dengweijun.com/'}

  s.ios.deployment_target = '9.0'

  s.source_files = 'Classes/**/*'
  
  s.resource_bundles = {
    'c' => 'Assets/c.json',
    'd' => 'Assets/d.json'
  }

end
