#!/usr/bin/env python3
"""Regenerate the conventional checked-in Xcode project. No third-party generator."""
from pathlib import Path
import hashlib, json
root = Path(__file__).resolve().parents[1]
objects = {}
def uid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def quote(value): return json.dumps(str(value))
def add(name, value):
    objects[uid(name)] = value
    return uid(name)
def array(values): return '(' + ', '.join(values) + (',' if values else '') + ')'
def obj(**kwargs): return '{' + ' '.join(f'{k} = {v};' for k,v in kwargs.items()) + '}'
def files(folder, test=False):
    refs, sources, resources = [], [], []
    for p in sorted((root / folder).rglob('*')):
        if not p.is_file() or p.name.startswith('.'): continue
        ext = p.suffix
        if ext not in {'.swift','.c','.h','.m','.mm','.metal','.icns','.xcassets','.txt','.html'}: continue
        path = str(p.relative_to(root))
        typ = {'.swift':'sourcecode.swift','.c':'sourcecode.c.c','.h':'sourcecode.c.h','.m':'sourcecode.c.objc','.mm':'sourcecode.cpp.objcpp','.metal':'sourcecode.metal','.icns':'image.icns','.xcassets':'folder.assetcatalog','.txt':'text','.html':'text.html'}[ext]
        ref = add('file:'+path, obj(isa='PBXFileReference',lastKnownFileType=typ,path=quote(path),sourceTree=quote('<group>')))
        refs.append(ref)
        if ext in {'.swift','.c','.m','.mm','.metal'}:
            sources.append(add('build:'+path,obj(isa='PBXBuildFile',fileRef=ref)))
        if ext in {'.icns','.xcassets','.txt','.html'}:
            resources.append(add('build:'+path,obj(isa='PBXBuildFile',fileRef=ref)))
    return refs,sources,resources
apprefs, appsources, appresources = files('OMTReceiver')
testrefs, testsources, _ = files('OMTReceiverTests',True)
appProduct=add('appProduct',obj(isa='PBXFileReference',explicitFileType=quote('wrapper.application'),includeInIndex='0',path=quote('OMTReceiver.app'),sourceTree='BUILT_PRODUCTS_DIR'))
testProduct=add('testProduct',obj(isa='PBXFileReference',explicitFileType=quote('wrapper.cfbundle'),includeInIndex='0',path=quote('OMTReceiverTests.xctest'),sourceTree='BUILT_PRODUCTS_DIR'))
base=add('baseconfig',obj(isa='PBXFileReference',lastKnownFileType='text.xcconfig',path=quote('Config/Base.xcconfig'),sourceTree=quote('<group>')))
groups=[]
for name,refs in [('OMTReceiver',apprefs),('OMTReceiverTests',testrefs),('Products',[appProduct,testProduct])]:
    groups.append(add('group:'+name,obj(isa='PBXGroup',children=array(refs),name=quote(name),sourceTree=quote('<group>'))))
main=add('mainGroup',obj(isa='PBXGroup',children=array(groups+[base]),sourceTree=quote('<group>')))
def phase(name,kind,buildfiles):
    return add(name,obj(isa=kind,buildActionMask='2147483647',files=array(buildfiles),runOnlyForDeploymentPostprocessing='0'))
sparklePackage=add('sparklePackage',obj(isa='XCRemoteSwiftPackageReference',repositoryURL=quote('https://github.com/sparkle-project/Sparkle'),requirement='{kind = exactVersion; version = 2.9.6;}'))
sparkleProduct=add('sparkleProduct',obj(isa='XCSwiftPackageProductDependency',package=sparklePackage,productName='Sparkle'))
sparkleBuild=add('sparkleBuild',obj(isa='PBXBuildFile',productRef=sparkleProduct))
plistPhase=add('generatePlist',obj(isa='PBXShellScriptBuildPhase',buildActionMask='2147483647',files='()',inputPaths=array([quote('$(SRCROOT)/VERSION'),quote('$(SRCROOT)/OMTReceiver/Resources/Info.plist'),quote('$(SRCROOT)/scripts/generate-info-plist.sh')]),outputPaths=array([quote('$(DERIVED_FILE_DIR)/OMTReceiver-Info.plist')]),alwaysOutOfDate='1',name=quote('Generate Versioned Info.plist'),runOnlyForDeploymentPostprocessing='0',shellPath=quote('/bin/bash'),shellScript=quote('"${SRCROOT}/scripts/generate-info-plist.sh" "${SRCROOT}/VERSION" "${SRCROOT}/OMTReceiver/Resources/Info.plist" "${DERIVED_FILE_DIR}/OMTReceiver-Info.plist"')))
appPhases=[plistPhase,phase('appSources','PBXSourcesBuildPhase',appsources),phase('appFrameworks','PBXFrameworksBuildPhase',[sparkleBuild]),phase('appResources','PBXResourcesBuildPhase',appresources)]
embed=add('embedSDK',obj(isa='PBXShellScriptBuildPhase',buildActionMask='2147483647',files='()',inputPaths='()',outputPaths='()',alwaysOutOfDate='1',name=quote('Embed and Sign OMT SDK'),runOnlyForDeploymentPostprocessing='0',shellPath=quote('/bin/sh'),shellScript=quote('"${SRCROOT}/scripts/embed-sdk.sh"')))
appPhases.append(embed)
testPhases=[phase('testSources','PBXSourcesBuildPhase',testsources),phase('testFrameworks','PBXFrameworksBuildPhase',[]),phase('testResources','PBXResourcesBuildPhase',[])]
def configList(name,kind):
    refs=[]
    for config in ['Debug','Release']:
        settings={}
        if kind=='project':
            settings={'CLANG_WARN_DOCUMENTATION_COMMENTS':'YES','CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER':'YES','GCC_WARN_64_TO_32_BIT_CONVERSION':'YES','SWIFT_OPTIMIZATION_LEVEL':quote('-Onone' if config=='Debug' else '-O'),'DEBUG_INFORMATION_FORMAT':quote('dwarf' if config=='Debug' else 'dwarf-with-dsym'),'ENABLE_TESTABILITY':'YES' if config=='Debug' else 'NO','SWIFT_ACTIVE_COMPILATION_CONDITIONS':quote('DEBUG $(inherited)' if config=='Debug' else '$(inherited)')}
        elif kind=='app': settings={'ASSETCATALOG_COMPILER_APPICON_NAME':quote(''),'COMBINE_HIDPI_IMAGES':'YES','SKIP_INSTALL':'NO'}
        else:
            settings={'PRODUCT_BUNDLE_IDENTIFIER':quote('com.suku.OMTReceiver-macOS.tests'),'PRODUCT_NAME':quote('OMTReceiverTests'),'INFOPLIST_FILE':quote(''),'GENERATE_INFOPLIST_FILE':'YES','SWIFT_OBJC_BRIDGING_HEADER':quote('OMTReceiverTests/TestSupport.h'),'BUNDLE_LOADER':quote('$(TEST_HOST)'),'TEST_HOST':quote('$(BUILT_PRODUCTS_DIR)/OMTReceiver.app/Contents/MacOS/OMTReceiver'),'LD_RUNPATH_SEARCH_PATHS':quote('$(inherited) @loader_path/../Frameworks @executable_path/../Frameworks')}
        args={'isa':'XCBuildConfiguration','buildSettings':obj(**settings),'name':quote(config)}
        if kind=='project': args['baseConfigurationReference']=base
        refs.append(add(name+config,obj(**args)))
    return add(name+'List',obj(isa='XCConfigurationList',buildConfigurations=array(refs),defaultConfigurationIsVisible='0',defaultConfigurationName=quote('Release')))
projectConfig=configList('projectConfig','project'); appConfig=configList('appConfig','app'); testConfig=configList('testConfig','test')
proxy=add('proxy',obj(isa='PBXContainerItemProxy',containerPortal=uid('project'),proxyType='1',remoteGlobalIDString=uid('appTarget'),remoteInfo=quote('OMTReceiver')))
dependency=add('dependency',obj(isa='PBXTargetDependency',target=uid('appTarget'),targetProxy=proxy))
appTarget=add('appTarget',obj(isa='PBXNativeTarget',buildConfigurationList=appConfig,buildPhases=array(appPhases),buildRules='()',dependencies='()',name=quote('OMTReceiver'),productName=quote('OMTReceiver'),packageProductDependencies=array([sparkleProduct]),productReference=appProduct,productType=quote('com.apple.product-type.application')))
testTarget=add('testTarget',obj(isa='PBXNativeTarget',buildConfigurationList=testConfig,buildPhases=array(testPhases),buildRules='()',dependencies=array([dependency]),name=quote('OMTReceiverTests'),productName=quote('OMTReceiverTests'),productReference=testProduct,productType=quote('com.apple.product-type.bundle.unit-test')))
project=add('project',obj(isa='PBXProject',attributes='{BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600;}',buildConfigurationList=projectConfig,compatibilityVersion=quote('Xcode 14.0'),developmentRegion='en',hasScannedForEncodings='0',knownRegions='(en, Base)',mainGroup=main,productRefGroup=groups[-1],projectDirPath=quote(''),projectRoot=quote(''),packageReferences=array([sparklePackage]),targets=array([appTarget,testTarget])))
path=root/'OMTReceiver.xcodeproj'; path.mkdir(exist_ok=True)
(path/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(f'{key} = {value};' for key,value in objects.items())+ f'\n}}; rootObject = {project};}}\n')
scheme=path/'xcshareddata/xcschemes'; scheme.mkdir(parents=True,exist_ok=True)
def ref(target, name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:OMTReceiver.xcodeproj"/>'
(scheme/'OMTReceiver.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref(appTarget,'OMTReceiver.app')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(testTarget,'OMTReceiverTests.xctest')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(appTarget,'OMTReceiver.app')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref(appTarget,'OMTReceiver.app')}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print('Generated OMTReceiver.xcodeproj')
