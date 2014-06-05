Pod::Spec.new do |s|
  s.name                  = 'Origin'
  s.version               = '0.1.0'
  s.summary               = 'Objective-C client library for Goonbee\'s chat service, for iOS and OS X.'
  s.homepage              = 'https://github.com/lmirosevic/Origin-client'
  s.license               = { type: 'Apache License, Version 2.0', file: 'LICENSE' }
  s.author                = { 'Luka Mirosevic' => 'luka@goonbee.com' }
  s.source                = { git: 'https://github.com/lmirosevic/Origin-client.git', tag: s.version.to_s }
  s.ios.deployment_target = '5.0'
  s.osx.deployment_target = '10.7'
  s.requires_arc          = true
  s.source_files          = 'Origin/Origin.{h,m}'
  s.public_header_files   = 'Origin/Origin.h'


end
