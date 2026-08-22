platform :ios, '12.0'
use_frameworks!

target 'NASPhotoAlbum' do
  # AMSMB2 2.7.1 是 2.x 最后一个版本（2020-03，要求 iOS 10+）
  # 3.x 起改用 async/await 并要求更高系统版本，不兼容 iOS 12
  # 以动态框架方式链接，同时满足 libsmb2 的 LGPL 许可要求
  pod 'AMSMB2', '2.7.1'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '12.0'
      config.build_settings['ENABLE_BITCODE'] = 'NO'
    end
  end
end
