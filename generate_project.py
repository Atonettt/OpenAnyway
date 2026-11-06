from pathlib import Path
import hashlib, json
root=Path(__file__).resolve().parent
src=root/'OpenAnyway'
project=root/'OpenAnyway.xcodeproj'/'project.pbxproj'
files=sorted(p.relative_to(src).as_posix() for p in src.rglob('*.swift'))

def key(string): return hashlib.sha1(string.encode()).hexdigest()[:24].upper()

app_ref=key('PRODUCT_APP')
assets_ref=key('ASSET_REF')
assets_bld=key('ASSET_BUILD')
root_group=key('ROOT_GROUP')
source_group=key('SOURCE_GROUP')
core_group=key('CORE_GROUP')
ui_group=key('UI_GROUP')
products_group=key('PRODUCTS_GROUP')
project_id=key('PROJECT')
target_id=key('TARGET')
sources_phase=key('SOURCES_PHASE')
resources_phase=key('RESOURCES_PHASE')
frameworks_phase=key('FRAMEWORKS_PHASE')
project_config_list=key('PROJECT_CONFIG_LIST')
target_config_list=key('TARGET_CONFIG_LIST')
project_debug=key('PROJECT_DEBUG')
project_release=key('PROJECT_RELEASE')
target_debug=key('TARGET_DEBUG')
target_release=key('TARGET_RELEASE')

q=lambda x: '"'+str(x).replace('\\','\\\\').replace('"','\\"')+'"'
lines=[]
add=lines.append
add('// !$*UTF8*$!')
add('{')
add('\tarchiveVersion = 1;')
add('\tclasses = {};')
add('\tobjectVersion = 56;')
add('\tobjects = {')
add('\n/* Begin PBXBuildFile section */')
for f in files:
    add(f'\t\t{key("BUILD_"+f)} /* {Path(f).name} in Sources */ = {{isa = PBXBuildFile; fileRef = {key("FILE_"+f)} /* {Path(f).name} */; }};')
add(f'\t\t{assets_bld} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_ref} /* Assets.xcassets */; }};')
add('/* End PBXBuildFile section */\n')
add('/* Begin PBXFileReference section */')
for f in files:
    add(f'\t\t{key("FILE_"+f)} /* {Path(f).name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(Path(f).name)}; sourceTree = "<group>"; }};')
add(f'\t\t{assets_ref} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
add(f'\t\t{app_ref} /* OpenAnyway.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = OpenAnyway.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
add('/* End PBXFileReference section */\n')
add('/* Begin PBXFrameworksBuildPhase section */')
add(f'\t\t{frameworks_phase} /* Frameworks */ = {{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }};')
add('/* End PBXFrameworksBuildPhase section */\n')
add('/* Begin PBXGroup section */')
add(f'\t\t{root_group} = {{isa = PBXGroup; children = ({source_group} /* OpenAnyway */, {products_group} /* Products */, ); sourceTree = "<group>"; }};')
add(f'\t\t{source_group} /* OpenAnyway */ = {{isa = PBXGroup; children = (')
for f in files:
    if '/' not in f: add(f'\t\t\t{key("FILE_"+f)} /* {Path(f).name} */,')
add(f'\t\t\t{core_group} /* Core */,')
add(f'\t\t\t{ui_group} /* UI */,')
add(f'\t\t\t{assets_ref} /* Assets.xcassets */,')
add('\t\t); path = OpenAnyway; sourceTree = "<group>"; };')
for folder, grp in [('Core',core_group),('UI',ui_group)]:
    add(f'\t\t{grp} /* {folder} */ = {{isa = PBXGroup; children = (')
    for f in files:
        if f.startswith(folder+'/'): add(f'\t\t\t{key("FILE_"+f)} /* {Path(f).name} */,')
    add(f'\t\t); path = {folder}; sourceTree = "<group>"; }};')
add(f'\t\t{products_group} /* Products */ = {{isa = PBXGroup; children = ({app_ref} /* OpenAnyway.app */, ); name = Products; sourceTree = "<group>"; }};')
add('/* End PBXGroup section */\n')
add('/* Begin PBXNativeTarget section */')
add(f'\t\t{target_id} /* OpenAnyway */ = {{')
add('\t\t\tisa = PBXNativeTarget;')
add(f'\t\t\tbuildConfigurationList = {target_config_list} /* Build configuration list for PBXNativeTarget "OpenAnyway" */;')
add(f'\t\t\tbuildPhases = ({sources_phase} /* Sources */, {frameworks_phase} /* Frameworks */, {resources_phase} /* Resources */, );')
add('\t\t\tbuildRules = (); dependencies = (); name = OpenAnyway;')
add(f'\t\t\tproductName = OpenAnyway; productReference = {app_ref} /* OpenAnyway.app */; productType = "com.apple.product-type.application";')
add('\t\t};')
add('/* End PBXNativeTarget section */\n')
add('/* Begin PBXProject section */')
add(f'\t\t{project_id} /* Project object */ = {{')
add('\t\t\tisa = PBXProject;')
add('\t\t\tattributes = {')
add('\t\t\t\tBuildIndependentTargetsInParallel = 1;')
add('\t\t\t\tLastUpgradeCheck = 1600;')
add(f'\t\t\t\tTargetAttributes = {{{target_id} = {{CreatedOnToolsVersion = 16.0; }}; }};')
add('\t\t\t};')
add(f'\t\t\tbuildConfigurationList = {project_config_list} /* Build configuration list for PBXProject "OpenAnyway" */;')
add('\t\t\tcompatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans;')
add('\t\t\thasScannedForEncodings = 0; knownRegions = (zh-Hans, en, Base, );')
add(f'\t\t\tmainGroup = {root_group}; productRefGroup = {products_group}; projectDirPath = ""; projectRoot = "";')
add(f'\t\t\ttargets = ({target_id} /* OpenAnyway */, );')
add('\t\t};')
add('/* End PBXProject section */\n')
add('/* Begin PBXResourcesBuildPhase section */')
add(f'\t\t{resources_phase} /* Resources */ = {{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({assets_bld} /* Assets.xcassets in Resources */, ); runOnlyForDeploymentPostprocessing = 0; }};')
add('/* End PBXResourcesBuildPhase section */\n')
add('/* Begin PBXSourcesBuildPhase section */')
add(f'\t\t{sources_phase} /* Sources */ = {{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (')
for f in files: add(f'\t\t\t{key("BUILD_"+f)} /* {Path(f).name} in Sources */,')
add('\t\t); runOnlyForDeploymentPostprocessing = 0; };')
add('/* End PBXSourcesBuildPhase section */\n')
add('/* Begin XCBuildConfiguration section */')
base_settings={
 'ALWAYS_SEARCH_USER_PATHS':'NO', 'CLANG_ENABLE_MODULES':'YES', 'CLANG_ENABLE_OBJC_ARC':'YES',
 'CLANG_WARN_DOCUMENTATION_COMMENTS':'YES', 'COPY_PHASE_STRIP':'NO',
 'ENABLE_STRICT_OBJC_MSGSEND':'YES', 'MACOSX_DEPLOYMENT_TARGET':'13.0',
 'SDKROOT':'macosx', 'SWIFT_VERSION':'5.0', 'SWIFT_OPTIMIZATION_LEVEL':'"-Onone"',
 'GCC_OPTIMIZATION_LEVEL':'0', 'DEBUG_INFORMATION_FORMAT':'dwarf',
}

def settings_lines(settings):
    return '\n'.join(f'\t\t\t\t{k} = {v};' for k,v in settings.items())
for name, ident, config, is_target in [
    ('Debug',project_debug,'debug',False),('Release',project_release,'release',False),
    ('Debug',target_debug,'debug',True),('Release',target_release,'release',True)]:
    if not is_target:
        s=base_settings.copy()
        if config=='release': s.update({'SWIFT_OPTIMIZATION_LEVEL':'"-O"','GCC_OPTIMIZATION_LEVEL':'s','DEBUG_INFORMATION_FORMAT':'"dwarf-with-dsym"'})
        else: s.update({'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG'})
    else:
        s={
          'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon', 'CODE_SIGN_STYLE':'Manual',
          'CODE_SIGN_IDENTITY':'"-"', 'CODE_SIGNING_ALLOWED':'YES',
          'COMBINE_HIDPI_IMAGES':'YES', 'ENABLE_HARDENED_RUNTIME':'NO',
          'GENERATE_INFOPLIST_FILE':'YES', 'INFOPLIST_KEY_CFBundleDisplayName':'"OpenAnyway"', 'INFOPLIST_KEY_CFBundleName':'"OpenAnyway"',
          'INFOPLIST_KEY_LSApplicationCategoryType':'"public.app-category.utilities"',
          'MACOSX_DEPLOYMENT_TARGET':'13.0', 'PRODUCT_BUNDLE_IDENTIFIER':'"io.github.atonettt.openanyway"',
          'PRODUCT_NAME':'"OpenAnyway"', 'SDKROOT':'macosx',
          'SUPPORTED_PLATFORMS':'macosx', 'SWIFT_VERSION':'5.0',
          'ONLY_ACTIVE_ARCH':'YES' if config=='debug' else 'NO',
          'SWIFT_EMIT_LOC_STRINGS':'YES', 'MARKETING_VERSION':'2.1.0', 'CURRENT_PROJECT_VERSION':'1', 'INFOPLIST_KEY_NSHumanReadableCopyright':'"© 2026 Atonettt"',
        }
    add(f'\t\t{ident} /* {name} */ = {{isa = XCBuildConfiguration; buildSettings = {{')
    add(settings_lines(s))
    add(f'\t\t\t}}; name = {name}; }};')
add('/* End XCBuildConfiguration section */\n')
add('/* Begin XCConfigurationList section */')
add(f'\t\t{project_config_list} /* Build configuration list for PBXProject "OpenAnyway" */ = {{isa = XCConfigurationList; buildConfigurations = ({project_debug} /* Debug */, {project_release} /* Release */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
add(f'\t\t{target_config_list} /* Build configuration list for PBXNativeTarget "OpenAnyway" */ = {{isa = XCConfigurationList; buildConfigurations = ({target_debug} /* Debug */, {target_release} /* Release */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }};')
add('/* End XCConfigurationList section */')
add('\t};')
add(f'\trootObject = {project_id} /* Project object */;')
add('}')
project.write_text('\n'.join(lines)+'\n',encoding='utf-8')
print(f'Generated Xcode project with {len(files)} Swift files')
