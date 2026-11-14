# npx cap add ios 다음에 실행: 인쇄 플러그인 추가, iPhone 전용, 버전 설정
require 'xcodeproj'
proj_path = 'ios/App/App.xcodeproj'
proj = Xcodeproj::Project.open(proj_path)
target = proj.targets.find { |t| t.name == 'App' }
group = proj.main_group.find_subpath('App', false)
%w[WebPrintPlugin.swift MyViewController.swift].each do |f|
  next if group.files.any? { |r| r.path == f }
  ref = group.new_reference(f)
  target.add_file_references([ref])
end
target.build_configurations.each do |c|
  c.build_settings['TARGETED_DEVICE_FAMILY'] = '1'
  c.build_settings['MARKETING_VERSION'] = ENV['APP_VERSION'] || '1.0.0'
  c.build_settings['CURRENT_PROJECT_VERSION'] = ENV['BUILD_NUMBER'] || '1'
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '14.0'
end
proj.save
puts 'Xcode project updated'
