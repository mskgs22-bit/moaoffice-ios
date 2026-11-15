# npx cap add ios 다음에 실행: iPhone 전용, 버전 설정
require 'xcodeproj'
proj = Xcodeproj::Project.open('ios/App/App.xcodeproj')
target = proj.targets.find { |t| t.name == 'App' }
target.build_configurations.each do |c|
  c.build_settings['TARGETED_DEVICE_FAMILY'] = '1'
  c.build_settings['MARKETING_VERSION'] = ENV['APP_VERSION'] || '1.0.0'
  c.build_settings['CURRENT_PROJECT_VERSION'] = ENV['BUILD_NUMBER'] || '1'
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '14.0'
end
proj.save
puts 'Xcode project updated'
