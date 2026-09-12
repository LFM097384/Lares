# 给 Runner.xcodeproj 程序化添加 LaresWidget(WidgetKit)target。
# 用法:ruby ios/add_widget_target.rb(幂等,已有则跳过)
# 依赖:gem install xcodeproj(CI macOS runner 自带 ruby)
require 'xcodeproj'

PROJ_PATH = File.join(__dir__, 'Runner.xcodeproj')
WIDGET_NAME = 'LaresWidget'
APP_GROUP = 'group.com.example.lares_app'
BUNDLE_PREFIX = 'com.example.lares_app'

proj = Xcodeproj::Project.open(PROJ_PATH)

if proj.targets.any? { |t| t.name == WIDGET_NAME }
  puts "#{WIDGET_NAME} 已存在,跳过"
  exit 0
end

app_target = proj.targets.find { |t| t.name == 'Runner' }
abort '找不到 Runner target' if app_target.nil?

# 1) 创建 Widget Extension target
widget = proj.new_target(:app_extension, WIDGET_NAME, :ios, '17.0')

# 2) 源码与资源
group = proj.main_group.new_group(WIDGET_NAME, WIDGET_NAME)
swift = group.new_file('LaresWidget.swift')
widget.add_file_references([swift])
# Info.plist 仅作为构建设置引用,不进编译资源
group.new_file('Info.plist')
group.new_file('LaresWidget.entitlements')

# 3) 构建设置
widget.build_configurations.each do |c|
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "#{BUNDLE_PREFIX}.#{WIDGET_NAME}"
  c.build_settings['INFOPLIST_FILE'] = "#{WIDGET_NAME}/Info.plist"
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = "#{WIDGET_NAME}/#{WIDGET_NAME}.entitlements"
  c.build_settings['SWIFT_VERSION'] = '5.0'
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  c.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  c.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  c.build_settings['MARKETING_VERSION'] = '0.1.0'
  c.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  c.build_settings['PRODUCT_NAME'] = WIDGET_NAME
  c.build_settings['LD_RUNPATH_SEARCH_PATHS'] = [
    '$(inherited)',
    '@executable_path/Frameworks',
    '@executable_path/../../Frameworks',
  ]
end

# 4) Runner entitlements 接入 App Groups(文件已在仓库)
app_target.build_configurations.each do |c|
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Runner/Runner.entitlements'
end

# 5) 依赖 + 嵌入到主 App
app_target.add_dependency(widget)
embed = app_target.new_copy_files_build_phase('Embed App Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
embed.add_file_reference(widget.product_reference)

proj.save(PROJ_PATH)
puts "#{WIDGET_NAME} target 已添加并嵌入 Runner"
