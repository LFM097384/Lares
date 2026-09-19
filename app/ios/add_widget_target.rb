# 给 Runner.xcodeproj 程序化添加 LaresWidget(WidgetKit)target。
# 用法:ruby ios/add_widget_target.rb(幂等,已有则跳过)
# 依赖:gem install xcodeproj(CI macOS runner 自带 ruby)
require 'xcodeproj'

PROJ_PATH = File.join(__dir__, 'Runner.xcodeproj')
WIDGET_NAME = 'LaresWidget'
APP_GROUP = 'group.com.lfm097384.lares'

# 版本号从 pubspec.yaml 读(唯一事实源)。
# 为什么必须在这里注入:extension 版本号与主 App 不一致时 **App Store 拒收整个包**,
# 而主 App 走 $(FLUTTER_BUILD_NAME)/$(FLUTTER_BUILD_NUMBER) —— 那两个变量来自
# Flutter 生成的 Generated.xcconfig,Widget target 并不继承它,取不到值。
# pubspec 的 version 行形如 `version: 0.1.1+2`。
pubspec_path = File.join(__dir__, '..', 'pubspec.yaml')
m = File.read(pubspec_path).match(/^version:\s*(\d+(?:\.\d+)*)\+(\d+)\s*$/)
abort '读不到 pubspec.yaml 的 version(期望形如 `version: 0.1.1+2`)' if m.nil?
MARKETING_VERSION = m[1]
BUILD_NUMBER = m[2]
puts "版本号(取自 pubspec):#{MARKETING_VERSION}+#{BUILD_NUMBER}"

proj = Xcodeproj::Project.open(PROJ_PATH)

runner = proj.targets.find { |t| t.name == 'Runner' }
abort '找不到 Runner target' if runner.nil?

# ── 0) 隐私清单接入 Runner 的 Copy Bundle Resources ──
#
# ⚠️ 必须放在下面那个「Widget 已存在就 exit」的幂等闸门**之前**,
# 否则 target 已存在时整段被跳过,清单永远进不了包。
#
# 为什么需要这一步:本项目走 SPM 而非 CocoaPods,没有 pod install 的
# 自动挂载 hook。PrivacyInfo.xcprivacy 只是躺在仓库里不会被打包,
# 表现是上传 App Store 时报 ITMS-91053(缺少隐私清单)——**本地毫无征兆**。
PRIVACY_FILE = 'PrivacyInfo.xcprivacy'
resources = runner.resources_build_phase
already = resources.files_references.any? do |fr|
  fr.respond_to?(:path) && fr.path.to_s.end_with?(PRIVACY_FILE)
end
if already
  puts "#{PRIVACY_FILE} 已在 Copy Bundle Resources,跳过"
else
  runner_group = proj.main_group.find_subpath('Runner', true)
  ref = runner_group.files.find { |f| f.path.to_s.end_with?(PRIVACY_FILE) } ||
        runner_group.new_file(PRIVACY_FILE)
  resources.add_file_reference(ref)
  proj.save(PROJ_PATH)
  puts "#{PRIVACY_FILE} 已加入 Runner 的 Copy Bundle Resources"
end

# ── 0.5) InfoPlist.strings 本地化:让图标下的名字随系统语言变 ──
#
# 同样必须在幂等闸门**之前** —— 理由同上。
#
# 为什么需要:App Store 主语言是 English,商店名叫 Lares Circle,
# 但 Info.plist 里只能写死一个 CFBundleDisplayName。
# 靠 en.lproj / zh-Hans.lproj 的 InfoPlist.strings 才能做到
# 英文机显示 Lares Circle、中文机显示「炉灵」。
#
# 这里同时覆盖了两条权限说明 —— 英文机上弹出中文权限弹窗
# 是 Guideline 5.1.1 的直接拒绝理由。
#
# 注意 knownRegions:工程原本只有 en 和 Base,不把 zh-Hans 加进去,
# 那个 .lproj 会被 Xcode 当成普通目录忽略,**不报错、也不生效**。
LOCALES = %w[en zh-Hans].freeze
INFOPLIST_STRINGS = 'InfoPlist.strings'

proj.root_object.known_regions |= LOCALES

runner_group = proj.main_group.find_subpath('Runner', true)
existing_var = runner_group.files.find do |f|
  f.path.to_s.end_with?(INFOPLIST_STRINGS) ||
    (f.respond_to?(:name) && f.name.to_s == INFOPLIST_STRINGS)
end

if existing_var
  puts "#{INFOPLIST_STRINGS} 已接入,跳过"
else
  # 变体组(variant group)是 Xcode 表达「同一资源的多语言版本」的方式:
  # 组名是 InfoPlist.strings,组里每个子文件对应一种语言。
  var_group = runner_group.new_variant_group(INFOPLIST_STRINGS)
  LOCALES.each do |loc|
    ref = var_group.new_file("#{loc}.lproj/#{INFOPLIST_STRINGS}")
    ref.name = loc
  end
  runner.resources_build_phase.add_file_reference(var_group)
  proj.save(PROJ_PATH)
  puts "#{INFOPLIST_STRINGS} 已接入(#{LOCALES.join(', ')})"
end

if proj.targets.any? { |t| t.name == WIDGET_NAME }
  puts "#{WIDGET_NAME} 已存在,跳过"
  exit 0
end

app_target = runner

# 父 App 的真实 bundle id(注意 Flutter 默认是驼峰 laresApp 而非 lares_app)
BUNDLE_PREFIX = app_target.build_configurations
  .map { |c| c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] }
  .find { |id| id.is_a?(String) && !id.empty? && !id.start_with?('$') }
abort '读不到父 App bundle id' if BUNDLE_PREFIX.nil?
puts "父 App bundle id: #{BUNDLE_PREFIX}"

# 1) 创建 Widget Extension target
widget = proj.new_target(:app_extension, WIDGET_NAME, :ios, '17.0')

# 2) 源码与资源
group = proj.main_group.new_group(WIDGET_NAME, WIDGET_NAME)
swift = group.new_file('LaresWidget.swift')
widget.add_file_references([swift])
# Info.plist 仅作为构建设置引用,不进编译资源
group.new_file('Info.plist')
group.new_file('LaresWidget.entitlements')

# Localizable.strings:小组件在「添加小组件」选择器里的名字与说明。
# 审核员和用户都会看到这一屏,所以要随系统语言变。
# 与主 App 的 InfoPlist.strings 同理,用变体组表达多语言。
widget_strings = group.new_variant_group('Localizable.strings')
LOCALES.each do |loc|
  r = widget_strings.new_file("#{loc}.lproj/Localizable.strings")
  r.name = loc
end
widget.resources_build_phase.add_file_reference(widget_strings)

# 3) 构建设置
widget.build_configurations.each do |c|
  c.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "#{BUNDLE_PREFIX}.#{WIDGET_NAME}"
  c.build_settings['INFOPLIST_FILE'] = "#{WIDGET_NAME}/Info.plist"
  c.build_settings['CODE_SIGN_ENTITLEMENTS'] = "#{WIDGET_NAME}/#{WIDGET_NAME}.entitlements"
  c.build_settings['SWIFT_VERSION'] = '5.0'
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  c.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  c.build_settings['CURRENT_PROJECT_VERSION'] = BUILD_NUMBER
  c.build_settings['MARKETING_VERSION'] = MARKETING_VERSION
  c.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  c.build_settings['PRODUCT_NAME'] = WIDGET_NAME
  # 签名:走自动签名。CI 带 -allowProvisioningUpdates,
  # xcodebuild 会拿 ASC API 密钥去为这个 target 申请描述文件。
  #
  # Team ID 不写死,从命令行的 DEVELOPMENT_TEAM=... 继承 ——
  # 这样它不必进仓库,换团队也不用改脚本。
  #
  # ⚠️ 少了这两行,归档时 Widget 会因为找不到签名身份而失败,
  # 报错只会指向 target 名字,不会告诉你缺的是签名配置。
  c.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  c.build_settings['DEVELOPMENT_TEAM'] = '$(DEVELOPMENT_TEAM)'
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
# Embed 阶段必须插在 Flutter 模板的收尾脚本(Thin Binary)之前,否则 Xcode 报构建环(Cycle)
app_target.add_dependency(widget)
embed = app_target.new_copy_files_build_phase('Embed App Extensions')
embed.symbol_dst_subfolder_spec = :plug_ins
embed.add_file_reference(widget.product_reference)
app_target.build_phases.delete(embed)
thin_idx = app_target.build_phases.index { |p| p.display_name == 'Thin Binary' }
if thin_idx
  app_target.build_phases.insert(thin_idx, embed)
else
  # 没有 Thin Binary 时插到最后一个 Run Script 之前
  script_idx = app_target.build_phases.rindex { |p| p.is_a?(Xcodeproj::Project::Object::PBXShellScriptBuildPhase) }
  script_idx ? app_target.build_phases.insert(script_idx, embed) : app_target.build_phases << embed
end

proj.save(PROJ_PATH)
puts "#{WIDGET_NAME} target 已添加并嵌入 Runner"
