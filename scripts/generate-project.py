#!/usr/bin/env python3
"""Deterministic, dependency-free Xcode project generation. The generated project is committed."""
import hashlib, json, pathlib, os
ROOT = pathlib.Path(__file__).resolve().parents[1]
BUNDLE_ID = os.environ.get("FIXI_BUNDLE_ID", "com.antony.mendsight")
TEAM_ID = os.environ.get("FIXI_DEVELOPMENT_TEAM", "")
objects = {}
def ident(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def obj(identity, **fields):
    key = ident(identity); objects[key] = fields; return key
def encode(v, indent=0):
    if isinstance(v, dict):
        return '{\n' + ''.join('\t'*(indent+1)+json.dumps(k)+' = '+encode(val, indent+1)+';\n' for k,val in v.items()) + '\t'*indent+'}'
    if isinstance(v, list): return '(' + ', '.join(encode(x, indent) for x in v) + (',' if v else '') + ')'
    if isinstance(v, int): return str(v)
    return json.dumps(str(v))
def ref(path, kind): return obj('file:'+path, isa='PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='<group>')
def phase(name, kind, files):
    return obj(name, isa=kind, buildActionMask=2147483647, files=files, runOnlyForDeploymentPostprocessing=0)
def build_file(name, refid): return obj('build:'+name, isa='PBXBuildFile', fileRef=refid)
sources = sorted(ROOT.glob('Fixi/*.swift'))
resources = sorted(ROOT.glob('Fixi/Resources/*.json'))
resources += [p for p in [ROOT/'Fixi/Resources/FixiLaunch.storyboard'] if p.exists()]
resources += sorted(ROOT.glob('Fixi/Resources/*.xcassets'))
test_sources = sorted(ROOT.glob('FixiTests/*.swift'))
source_refs = [ref(str(p.relative_to(ROOT)), 'sourcecode.swift') for p in sources]
resource_refs = [ref(str(p.relative_to(ROOT)), 'folder.assetcatalog' if p.suffix == '.xcassets' else 'folder' if p.is_dir() else 'file.storyboard' if p.suffix == '.storyboard' else 'text.json') for p in resources]
config = ref('Config/App.xcconfig', 'text.xcconfig')
info = ref('Fixi/Info.plist', 'text.plist.xml')
test_refs = [ref(str(p.relative_to(ROOT)), 'sourcecode.swift') for p in test_sources]
product = obj('product', isa='PBXFileReference', explicitFileType='wrapper.application', path='Fixi.app', sourceTree='BUILT_PRODUCTS_DIR')
test_product = obj('test-product', isa='PBXFileReference', explicitFileType='wrapper.cfbundle', path='FixiTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
products = obj('products', isa='PBXGroup', children=[product,test_product], name='Products', sourceTree='<group>')
group = obj('group', isa='PBXGroup', children=source_refs+resource_refs+test_refs+[info,config,products], sourceTree='<group>')
package = obj('package', isa='XCRemoteSwiftPackageReference', repositoryURL='https://github.com/facebook/meta-wearables-dat-ios', requirement={'kind':'exactVersion','version':'1.0.1'})
dependencies = [obj('package:'+name, isa='XCSwiftPackageProductDependency', package=package, productName=name) for name in ['MWDATCore','MWDATCamera','MWDATDisplay','MWDATSpeech','MWDATInputs']]
frameworks = [obj('framework:'+name, isa='PBXBuildFile', productRef=pid) for name,pid in zip(['core','camera','display','speech','inputs'],dependencies)]
source_phase = phase('sources','PBXSourcesBuildPhase',[build_file(str(p),r) for p,r in zip(sources,source_refs)])
resource_phase = phase('resources','PBXResourcesBuildPhase',[build_file(str(p),r) for p,r in zip(resources,resource_refs)])
framework_phase = phase('frameworks','PBXFrameworksBuildPhase',frameworks)
test_source_phase = phase('test-sources','PBXSourcesBuildPhase',[build_file('test:'+str(p.relative_to(ROOT)),r) for p,r in zip(test_sources,test_refs)])
test_framework_phase = phase('test-frameworks','PBXFrameworksBuildPhase',[])
def config_list(name, base_settings, base=None):
    configs=[]
    for mode in ['Debug','Release']:
        settings=base_settings.copy()
        settings['SWIFT_OPTIMIZATION_LEVEL']='-Onone' if mode=='Debug' else '-O'
        if mode=='Debug': settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG $(inherited)'; settings['ENABLE_TESTABILITY']='YES'
        fields=dict(isa='XCBuildConfiguration', name=mode, buildSettings=settings)
        if base: fields['baseConfigurationReference']=base
        configs.append(obj(name+':'+mode, **fields))
    return obj(name+':list', isa='XCConfigurationList', buildConfigurations=configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
project_config=config_list('project-config',{'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.2','CLANG_ENABLE_MODULES':'YES','SWIFT_VERSION':'5.0','SWIFT_STRICT_CONCURRENCY':'targeted','DEBUG_INFORMATION_FORMAT':'dwarf-with-dsym'})
app_config=config_list('app-config',{'PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':BUNDLE_ID,'INFOPLIST_FILE':'Fixi/Info.plist','GENERATE_INFOPLIST_FILE':'NO','TARGETED_DEVICE_FAMILY':'1','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SUPPORTS_MACCATALYST':'NO','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':TEAM_ID,'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks','MARKETING_VERSION':'1.0','CURRENT_PROJECT_VERSION':'21'},config)
test_config=config_list('test-config',{'PRODUCT_NAME':'$(TARGET_NAME)','PRODUCT_BUNDLE_IDENTIFIER':BUNDLE_ID+'.tests','GENERATE_INFOPLIST_FILE':'YES','TARGETED_DEVICE_FAMILY':'1','CODE_SIGN_STYLE':'Automatic','DEVELOPMENT_TEAM':TEAM_ID,'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/Fixi.app/Fixi','BUNDLE_LOADER':'$(TEST_HOST)','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/Frameworks @loader_path/Frameworks'})
app=obj('app',isa='PBXNativeTarget',buildConfigurationList=app_config,buildPhases=[source_phase,framework_phase,resource_phase],buildRules=[],dependencies=[],name='Fixi',packageProductDependencies=dependencies,productName='Fixi',productReference=product,productType='com.apple.product-type.application')
proxy=obj('test-proxy',isa='PBXContainerItemProxy',containerPortal=ident('project'),proxyType=1,remoteGlobalIDString=app,remoteInfo='Fixi')
test_dependency=obj('test-dependency',isa='PBXTargetDependency',target=app,targetProxy=proxy)
test_target=obj('tests',isa='PBXNativeTarget',buildConfigurationList=test_config,buildPhases=[test_source_phase,test_framework_phase],buildRules=[],dependencies=[test_dependency],name='FixiTests',productName='FixiTests',productReference=test_product,productType='com.apple.product-type.bundle.unit-test')
project=obj('project',isa='PBXProject',attributes={'LastUpgradeCheck':'2640','TargetAttributes':{app:{'CreatedOnToolsVersion':'26.4'},test_target:{'CreatedOnToolsVersion':'26.4','TestTargetID':app}}},buildConfigurationList=project_config,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=group,packageReferences=[package],productRefGroup=products,projectDirPath='',projectRoot='',targets=[app,test_target])
folder=ROOT/'Fixi.xcodeproj'; folder.mkdir(exist_ok=True)
(folder/'project.pbxproj').write_text('// !$*UTF8*$!\n'+encode({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project})+'\n')
schemes=folder/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
def buildable(target, name, product): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:Fixi.xcodeproj"/>'
a=buildable(app,'Fixi','Fixi.app'); t=buildable(test_target,'FixiTests','FixiTests.xctest')
(schemes/'Fixi.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2640" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{a}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{t}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{a}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{a}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')

print('Generated Fixi.xcodeproj')
