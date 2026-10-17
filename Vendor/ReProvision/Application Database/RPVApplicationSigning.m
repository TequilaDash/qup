//
//  RPVApplicationSigning.m
//  iOS
//
//  Created by Matt Clarke on 09/01/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "RPVApplicationSigning.h"
#import "EEBackend.h"
#import "RPVApplication.h"
#import "RPVApplicationDatabase.h"

#import "SSZipArchive.h"
#import "RPVDiagnostics.h"

#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CommonCrypto/CommonDigest.h>

// MCProfileConnection (ManagedConfiguration) - used to register a provisioning
// profile with the system so the OS trusts the signed app. Accessed purely via the
// ObjC runtime so there's no link-time dependency in non-UI targets.
@interface MCProfileConnection : NSObject
+ (instancetype)sharedConnection;
@end

/* Private headers */
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)arg1 withOptions:(NSDictionary *)arg2 error:(NSError **)arg3;
- (NSArray *)allApplications;
- (BOOL)uninstallApplication:(id)arg1 withOptions:(id)arg2;
@end

/// 私有 API 编译期声明（仅声明、无实现；运行时命中 MIInstallOptions 真类实现）。
/// 选择器以 init 开头，ARC 自动按 +1 保留处理，规避 performSelector/objc_msgSend 的保留陷阱。
@interface NSObject (RPVMIInstallOptionsInit)
- (instancetype)initWithLegacyOptionsDictionary:(NSDictionary *)legacyOptions;
@end

/* 「>iOS18版本 切换方案」：iOS 26 起 LSApplicationWorkspace 的 install/uninstall 系列方法被苹果
   整个 stub 掉——方法体只剩"记一条 fault 日志 + 恒定返回"，什么都不做
   （iOS 26.1 固件反编译实锤：LSApplicationWorkspace.m 3015 行）。
   安装侧：LS 安装返回 NSOSStatusErrorDomain/-4 → 回退 InstallCoordination（IXAppInstallCoordinator）。
   卸载侧（iOS 26.0.1 真机实锤，bundleID=com.roooot.lara.U82B5LN29B）：
   LS uninstallApplication:withOptions: 直接返回 NO（被 stub），导致用户主动「卸载应用」弹窗提示失败。
   Uninstall 没有 InstallCoordination 等价入口，故回退到 MobileInstallation.framework 的
   MobileInstallationUninstall（对称 daemon 安装侧 MobileInstallationInstall 的 dlsym 模式）。
   非 iOS 26 一律保持原 LS 行为不变。 */

/// 系统主版本号（用于「>iOS18版本 切换方案」的版本门控）。
static NSInteger RPVSystemMajorVersion(void) {
    return (NSInteger)[[NSProcessInfo processInfo] operatingSystemVersion].majorVersion;
}

/// 「>iOS18版本 切换方案」：iOS 26 经 InstallCoordination（IXAppInstallCoordinator）直连 installd。
/// 同步等待 completion（超时 6 分钟）。options 必须为类型化 MIInstallOptions，
/// 故先以 initWithLegacyOptionsDictionary: 包装，再传给
/// _beginInstallForURL:forPersonaUniqueString:consumeSource:options:progressBlock:completionWithIdentity:。
/// 框架/类缺失等首失败返回 NO，调用方继续老路径。
static BOOL RPVBeginInstallWithInstallCoordination(NSURL *ipaURL, NSString *bundleIdentifier, NSError **outError) {
    if (outError) *outError = nil;
    static void *installCoordinationHandle = NULL;
    static void *mobileInstallationHandle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        installCoordinationHandle = dlopen("/System/Library/PrivateFrameworks/InstallCoordination.framework/InstallCoordination", RTLD_LAZY | RTLD_LOCAL);
        mobileInstallationHandle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY | RTLD_LOCAL);
    });
    if (installCoordinationHandle == NULL || mobileInstallationHandle == NULL) {
        if (outError) *outError = [NSError errorWithDomain:@"RPVInstallCoordination" code:-1
                                                  userInfo:@{NSLocalizedDescriptionKey: @"InstallCoordination/MobileInstallation 框架加载失败"}];
        return NO;
    }
    Class coordinatorClass = objc_getClass("IXAppInstallCoordinator");
    Class installOptionsClass = objc_getClass("MIInstallOptions");
    SEL selector = sel_registerName("_beginInstallForURL:forPersonaUniqueString:consumeSource:options:progressBlock:completionWithIdentity:");
    SEL optionsInitializer = sel_registerName("initWithLegacyOptionsDictionary:");
    if (coordinatorClass == Nil || installOptionsClass == Nil ||
        ![(id)coordinatorClass respondsToSelector:selector] ||
        ![installOptionsClass instancesRespondToSelector:optionsInitializer]) {
        if (outError) *outError = [NSError errorWithDomain:@"RPVInstallCoordination" code:-2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"InstallCoordination 运行时类/选择器不可用"}];
        return NO;
    }
    NSMutableDictionary *options = [NSMutableDictionary dictionaryWithDictionary:@{
        @"CFBundleIdentifier": bundleIdentifier ?: @"",
        @"AllowInstallLocalProvisioned": @YES,
    }];
    [options setObject:@YES forKey:@"IsUserInitiated"];
    [options setObject:@"Developer" forKey:@"PackageType"];
    [options setObject:@YES forKey:@"SkipWatchAppInstall"];

    typedef void (^RPVInstallCoordinationCompletion)(id _Nullable identity, NSError *_Nullable error);
    __block BOOL done = NO;
    __block BOOL success = NO;
    __block NSError *installError = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    RPVInstallCoordinationCompletion completion = ^(id identity, NSError *error) {
        success = (error == nil);
        installError = error;
        done = YES;
        dispatch_semaphore_signal(sema);
    };
    @try {
        // 裸 NSDictionary 会导致 installd 异步 unrecognized-selector（installTargetType）崩溃；
        // 必须先用 initWithLegacyOptionsDictionary: 包装成类型化 MIInstallOptions。
        id allocatedOptions = [(id)installOptionsClass alloc];
        id installOptions = [allocatedOptions initWithLegacyOptionsDictionary:options];
        if (installOptions == nil) {
            if (outError) *outError = [NSError errorWithDomain:@"RPVInstallCoordination" code:2
                                                      userInfo:@{NSLocalizedDescriptionKey: @"iOS 26 安装选项对象创建失败"}];
            return NO;
        }
        // 要求 InstallCoordination 拷贝（consumeSource=NO）而非异步删除源 IPA。
        ((void (*)(id, SEL, NSURL *, NSString *_Nullable, BOOL, id, id _Nullable, RPVInstallCoordinationCompletion))
         objc_msgSend)(coordinatorClass, selector, ipaURL, nil, NO, installOptions, nil, completion);
    } @catch (NSException *exception) {
        if (outError) *outError = [NSError errorWithDomain:@"RPVInstallCoordination" code:1
                                                  userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"iOS 26 安装服务抛出异常：%@", exception.reason ?: exception.name]}];
        return NO;
    }
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 6 * 60 * NSEC_PER_SEC));
    if (!done) {
        if (outError) *outError = [NSError errorWithDomain:@"RPVInstallCoordination" code:-3
                                                  userInfo:@{NSLocalizedDescriptionKey: @"iOS 26 安装超时（6 分钟）"}];
        return NO;
    }
    if (installError) { if (outError) *outError = installError; return NO; }
    return success;
}

/// 「>iOS18版本 切换方案」：iOS 26 下 LSApplicationWorkspace 卸载被 stub（恒定返回 NO），
/// 回退 MobileInstallation.framework 的 MobileInstallationUninstall
/// （对称 daemon 安装侧 MobileInstallationInstall 的 dlsym 模式，完成回调同为
///  void (^)(NSDictionary *result, NSError *error)）。框架/符号缺失或超时返回 NO。
static BOOL RPVUninstallWithMobileInstallation(NSString *bundleIdentifier, NSError **outError) {
    if (outError) *outError = nil;
    static void *mobileInstallationHandle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mobileInstallationHandle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY | RTLD_LOCAL);
    });
    if (mobileInstallationHandle == NULL) {
        if (outError) *outError = [NSError errorWithDomain:@"RPVUninstallMobileInstallation" code:-1
                                                  userInfo:@{NSLocalizedDescriptionKey: @"MobileInstallation 框架加载失败"}];
        return NO;
    }
    void (*uninstallFunc)(CFStringRef, CFDictionaryRef, void *, void *) =
        (void (*)(CFStringRef, CFDictionaryRef, void *, void *))dlsym(mobileInstallationHandle, "MobileInstallationUninstall");
    if (!uninstallFunc) {
        if (outError) *outError = [NSError errorWithDomain:@"RPVUninstallMobileInstallation" code:-2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"MobileInstallationUninstall 符号不存在（框架被 strip）"}];
        return NO;
    }
    NSDictionary *opts = @{ @"CFBundleIdentifier": bundleIdentifier ?: @"" };
    __block BOOL done = NO;
    __block BOOL ok = NO;
    __block NSString *errMsg = nil;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    void (^completion)(NSDictionary *, NSError *) = [^(NSDictionary *result, NSError *error) {
        ok = (error == nil);
        if (error) {
            errMsg = error.localizedDescription ?: @"未知错误";
        } else if ([result isKindOfClass:[NSDictionary class]] && [result[@"errorString"] length] > 0) {
            ok = NO;
            errMsg = result[@"errorString"];
        }
        done = YES;
        dispatch_semaphore_signal(sema);
    } copy];
    uninstallFunc((__bridge CFStringRef)bundleIdentifier,
                  (__bridge CFDictionaryRef)opts,
                  (__bridge void *)completion, NULL);
    long rc = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC));
    if (rc != 0 || !done) {
        if (outError) *outError = [NSError errorWithDomain:@"RPVUninstallMobileInstallation" code:-3
                                                  userInfo:@{NSLocalizedDescriptionKey: @"卸载超时（120 秒）"}];
        return NO;
    }
    if (!ok && outError) *outError = [NSError errorWithDomain:@"RPVUninstallMobileInstallation" code:-4
                                                     userInfo:@{NSLocalizedDescriptionKey: errMsg ?: @"未知错误"}];
    return ok;
}


@interface RPVApplicationSigning ()

@property (nonatomic, strong) NSMutableArray *installQueue;
@property (nonatomic, readwrite) BOOL undertakingResignPipeline;
@property (nonatomic, readwrite) UIBackgroundTaskIdentifier currentBackgroundTaskIdentifier;

/// 🔴 v1.1.163：并行 install 完成计数 + complete 一次性标志。
/// 原版用「!undertakingResignPipeline」当完成门：多 app 批量签名时，最后一个 app
/// 签名完成（_resignApplication 末尾）就把 pipeline 置 NO，此后**任何一个** install
/// 完成（含倒数第二个 app 的异步 install）都会误判为流水线结束 → 提前 endBackgroundTask
/// + 提前 applicationSigningCompleteWithError:nil → 上层（AppDelegate）立即写冷却、
/// 回报 daemon、后台路径 exit(0) → 后面 app 的 install 被进程退出打断，没装上。
/// 现在改为 install 计数归零 + pipeline 结束才 complete，且只通知一次。
@property (nonatomic, readwrite) NSInteger installCount;
@property (nonatomic, readwrite) BOOL pipelineCompleteNotified;

@property (nonatomic, strong) NSMutableArray *observers;

@end

static RPVApplicationSigning *sharedInstance;

// Injected by the app delegate: asks the root daemon (over XPC) to drop a
// provisioning profile into the real system profile store. See the header.
static BOOL (^_rpvDaemonProfileInstallHandler)(NSString *profilePath) = nil;

@implementation RPVApplicationSigning

+ (void)setDaemonProfileInstallHandler:(BOOL (^)(NSString *profilePath))handler {
    _rpvDaemonProfileInstallHandler = [handler copy];
}

+ (instancetype)sharedInstance {
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });

    return sharedInstance;
}

- (instancetype)init {
    self = [super init];

    if (self) {
        self.observers = [NSMutableArray array];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appShouldBeRemoved:) name:@"cn.analy.resign/appShouldBeRemoved" object:nil];
    }

    return self;
}

- (void)addSigningUpdatesObserver:(id<RPVApplicationSigningProtocol>)observer {
    [self.observers addObject:observer];
}

- (void)removeSigningUpdatesObserver:(id<RPVApplicationSigningProtocol>)observer {
    [self.observers removeObject:observer];
    // 🔴 v1.1.163：旧版这里还调了 removeObserver:self —— 会把 self 注册的
    // 「appShouldBeRemoved」通知监听也一并删掉（语义 bug）。observers 数组移除
    // 已足够，通知监听保持原样。
}

- (void)_resignApplicationsArray:(NSArray *)applications withTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void) {
        for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
            [observer applicationSigningDidStart];
        }

        // 🔴 v1.1.163：进入闸门加 @synchronized 保护 —— daemon 后台拉起续签与用户前台
        // 手动重签可能并发进入本方法（各自在全局队列的不同线程）。旧版 check-then-set
        // 非原子：两个流水线同时通过检查 → 双写 installQueue + 多线程 removeObjectAtIndex
        // → 「__NSArrayM mutated while being enumerated」崩溃（用户「杀后台再打开闪退」
        // 的代码侧根因之一）。加锁后第二个流水线在闸门处拿 AlreadyUndertaking 退出。
        BOOL alreadyRunning = NO;
        @synchronized (self) {
            if (self.undertakingResignPipeline) {
                alreadyRunning = YES;
            } else {
                self.undertakingResignPipeline = YES;
            }
        }

        if (alreadyRunning) {
            NSError *error = [self _errorFromString:@"Already undertaking the re-sign pipeline!" errorCode:RPVErrorAlreadyUndertakingPipeline];

            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:error];
            }
            return;
        }

        //////////////////////////////////////////////////////////////////////////////////////
        // 1. Do pre-flight checks.
        //////////////////////////////////////////////////////////////////////////////////////

        // TODO: Network connectivity.

        // Update install queue with new applications list
        self.installQueue = [applications mutableCopy];
        // v1.1.163：重置并行 install 计数与 complete 一次性标志（新流水线）
        @synchronized (self) {
            self.installCount = 0;
            self.pipelineCompleteNotified = NO;
        }

        //////////////////////////////////////////////////////////////////////////////////////
        // 2. Initiate signing for applications if applicable.
        //////////////////////////////////////////////////////////////////////////////////////

        // If no signing needed, just exit.
        if (self.installQueue.count == 0) {
            @synchronized (self) { self.undertakingResignPipeline = NO; }
            NSError *error = [self _errorFromString:@"No applications need re-signing" errorCode:RPVErrorNoSigningRequired];
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:error];
            }
            return;
        }

        // Move to a background task!
        // 🔴 v1.1.163：beginBackgroundTask 文档要求【主线程】调用（iOS 17 上非主线程
        // 调用可能抛异常）。本方法跑在全局队列，用 dispatch_sync 切主线程执行；
        // 主线程只跑 RunLoop，不会等待本全局队列任务完成，无死锁风险。
        UIApplication *application = [UIApplication sharedApplication];
        __block UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
        void (^beginTask)(void) = ^{
            bgTask = [application beginBackgroundTaskWithName:@"ReProvision Application Signing" expirationHandler:^{
                // Clean up any unfinished task business by marking where you
                // stopped or ending the task outright.
                [application endBackgroundTask:bgTask];
                bgTask = UIBackgroundTaskInvalid;
            }];
        };
        if ([NSThread isMainThread]) {
            beginTask();
        } else {
            dispatch_sync(dispatch_get_main_queue(), beginTask);
        }

        self.currentBackgroundTaskIdentifier = bgTask;

        // Update progress handler to 0% for all applications.
        for (RPVApplication *app in [self.installQueue reverseObjectEnumerator]) {
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningUpdateProgress:0 forBundleIdentifier:app.bundleIdentifier];
            }
        }

        // Start signing.
        [self _initiateNextInstallFromQueueWithTeamID:teamID
                                             username:username
                                             password:password];
    });
}

- (void)resignSpecificApplications:(NSArray *)applications withTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    [self _resignApplicationsArray:applications withTeamID:teamID username:username password:password];
}

- (void)resignApplications:(BOOL)onlyExpiringApplications thresholdForExpiration:(int)thresholdForExpiration withTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    //////////////////////////////////////////////////////////////////////////////////////
    // 0. Iterate over all the applications available in RPVApplicationDatabase.
    //////////////////////////////////////////////////////////////////////////////////////

    // Get list of applications from RPVApplicationDatabase
    NSMutableArray *applications = [NSMutableArray array];
    if (onlyExpiringApplications) {
        NSDate *now = [NSDate date];
        NSDate *expirationDate = [now dateByAddingTimeInterval:60 * 60 * 24 * thresholdForExpiration];

        if (![[RPVApplicationDatabase sharedInstance] getApplicationsWithExpiryDateBefore:&applications andAfter:nil date:expirationDate forTeamID:teamID]) {
            // sad times.
            self.undertakingResignPipeline = NO;
            NSError *error = [self _errorFromString:@"Failed to get applications within expiry date" errorCode:-1337];
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:error];
            }
            return;
        }
    } else {
        applications = [[[RPVApplicationDatabase sharedInstance] getAllApplicationsForTeamID:teamID] mutableCopy];
    }

    // v1.1.98: 过滤「小黑屋」（黑名单）。
    // 这一步同时覆盖 App 的批量续签与守护进程 repro-signingd 的自动续签（两者都走 resignApplications:），
    // 而单点「重签」/IPA 导入走 resignSpecificApplications:，不经过这里，所以手动签名仍可签黑名单应用。
    NSDictionary *blacklist = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"reproBlacklist"];
    if (blacklist.count > 0) {
        NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:applications.count];
        for (RPVApplication *app in applications) {
            NSString *bid = [app bundleIdentifier];
            if (bid.length > 0 && [blacklist objectForKey:bid] != nil) {
                NSLog(@"[ReSign] 小黑屋应用，跳过自动续签: %@", bid);
            } else {
                [filtered addObject:app];
            }
        }
        applications = filtered;
    }

    [self _resignApplicationsArray:applications withTeamID:teamID username:username password:password];
}

/**
 For the given RPVApplication, this method copies its .app bundle into a directory structure of
 an extracted IPA, in a temporary directory.

 @param extractedArchiveURL Output URL of where the root directory structure is located
 @param applicationBundleURL Output URL of where the application's bundle is located
 @param error If non-null, any arising error.
 @return Success
 */
- (BOOL)_copyApplicationBundleForApplication:(RPVApplication *)application extractedArchiveURL:(NSURL **)extractedArchiveURL applicationBundleURL:(NSURL **)applicationBundleURL error:(NSError **)error {
    NSString *temporaryDirectory = [EEBackend applicationTemporaryDirectory];
    NSString *dotAppName = @"";

    // 🔴 v2.2.5 治本（code=181 残留通道）：applicationTemporaryDirectory 是固定目录
    // （NSTemporaryDirectory），跨会话/跨次操作会残留上次的 Payload/*.app。而 RPVApplication
    // 分支（已安装 App 重签）只删同名 .app、repackIpaAtPath 打包整个目录树 → 上次残留的
    // App.app（与本次签的 Relaxin.app 同 bundleID）被带进 IPA → installd 报
    // "Multiple .app bundles with the bundle ID X were found within the installable"
    // （MIInstallerErrorDomain code=181，真机实测：Relaxin.app + App.app 同 id）。
    // 每次重签前整体清掉 tmp/<bundleID> 再重建，从源头杜绝残留混入 repack。
    NSString *targetRoot = [temporaryDirectory stringByAppendingPathComponent:[application bundleIdentifier]];
    NSFileManager *fmRoot = [NSFileManager defaultManager];
    if ([fmRoot fileExistsAtPath:targetRoot]) {
        if (![fmRoot removeItemAtPath:targetRoot error:nil]) {
            NSLog(@"[ReSign] v2.2.5: 清理临时目录失败（残留可能被带进 IPA）: %@", targetRoot);
        }
    }
    [fmRoot createDirectoryAtPath:targetRoot withIntermediateDirectories:YES attributes:nil error:nil];

    if ([application.class isEqual:[RPVApplication class]]) {
        NSString *applicationBundleLocation = [application locationOfApplicationOnFilesystem].path;
        dotAppName = [applicationBundleLocation lastPathComponent];

        NSString *toPath = [NSString stringWithFormat:@"%@/%@/Payload/%@", temporaryDirectory, [application bundleIdentifier], dotAppName];

        // Create the parent path if needed
        NSString *parentPath = [toPath stringByDeletingLastPathComponent];
        if (![[NSFileManager defaultManager] fileExistsAtPath:parentPath]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:parentPath withIntermediateDirectories:YES attributes:nil error:nil];
            // Delete any existing .app if needed too.
        } else if ([[NSFileManager defaultManager] fileExistsAtPath:toPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:toPath error:nil];
        }

        NSError *err;
        if (![[NSFileManager defaultManager] copyItemAtPath:applicationBundleLocation toPath:toPath error:&err]) {
            if (error) {
                *error = [self _errorFromString:err.localizedDescription errorCode:RPVErrorFailedToCopyBundle];
            }
            return NO;
        }

        // 诊断：列出最终 Payload 内容，核验残留是否已被清理（code=181 排查用）。
        NSArray *payloadList = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:parentPath error:nil];
        NSLog(@"[ReSign] v2.2.5: Payload 最终内容 = %@", [payloadList componentsJoinedByString:@", "]);

    } else {
        // This is an IPA application, therefore -locationOfApplicationOnFilesystem will return the .ipa
        // file on the filesystem.

        // We need to extract the IPA to our temporary location, and roll from there.
        NSString *extractionPath = [NSString stringWithFormat:@"%@/%@", temporaryDirectory, [application bundleIdentifier]];
        NSError *err;
        BOOL success = [SSZipArchive unzipFileAtPath:[application locationOfApplicationOnFilesystem].path
                                       toDestination:extractionPath
                                           overwrite:YES
                                            password:nil
                                               error:&err];

        if (success) {
            // 🔴 v2.2.4 修复「MIInstallerErrorDomain code=181」：原本只看 contentsOfDirectoryAtPath
            // 取第一条非 .DS_Store，Payload 下若多个 .app（如残留解压残骸并存，或用户打包出
            // 两个顶层 .app），只签名其中一个留其它裸奔 → installd 重打包后会看到多个 .app
            // 共享同一 CFBundleIdentifier，直接拒装
            // （"Multiple .app bundles with the bundle ID X were found within the installable"）。
            //
            // 这里是单 bundle 签名全项目的唯一入口（_initiateNextInstallFromQueueWithTeamID 全
            // 链路都走它），这里治住 = 自动续签、强制重签、批量重签三路同时修好。
            NSFileManager *fmScan = [NSFileManager defaultManager];
            NSString *payloadPath = [extractionPath stringByAppendingPathComponent:@"Payload"];
            NSArray<NSString *> *rawSubdirs = [fmScan contentsOfDirectoryAtPath:payloadPath error:nil] ?: @[];
            NSArray<NSString *> *sortedSubdirs = [rawSubdirs sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

            NSMutableArray<NSString *> *appBundles = [NSMutableArray array];
            for (NSString *entry in sortedSubdirs) {
                if ([entry isEqualToString:@".DS_Store"]) continue;
                if (![[entry pathExtension] isEqualToString:@"app"]) continue;
                NSString *full = [payloadPath stringByAppendingPathComponent:entry];
                BOOL isDir = NO;
                if ([fmScan fileExistsAtPath:full isDirectory:&isDir] && isDir) {
                    [appBundles addObject:entry];
                }
            }

            if (appBundles.count == 0) {
                // 比「直接 fall through 让 dotAppName 为空后面崩」更友好；上游会终止该次签名
                // 且把 userInfo.localizedDescription 透传给调用方。
                NSString *msg = [NSString stringWithFormat:
                    @"IPA 的 Payload 下未发现任何 .app 包（实际条目：%@），无法完成签名",
                    [sortedSubdirs componentsJoinedByString:@", "]];
                if (error) {
                    *error = [self _errorFromString:msg errorCode:RPVErrorFailedToCopyBundle];
                }
                return NO;
            }

            if (appBundles.count > 1) {
                // 多 .app 不一定冲突（Apple 内部两-app 一包的特化场景）——只有当多个 .app
                // 共享同一 CFBundleIdentifier 时 installd 才会报 code=181。这里逐个读
                // Info.plist 拼一份「id → [<bundles>]」表，重复 id 视为冲突并直接报错。
                NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *idsToBundles = [NSMutableDictionary dictionary];
                for (NSString *app in appBundles) {
                    NSString *infoPath = [[payloadPath stringByAppendingPathComponent:app]
                                          stringByAppendingPathComponent:@"Info.plist"];
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                    NSString *bid = ([info[@"CFBundleIdentifier"] isKindOfClass:[NSString class]]
                                      ? info[@"CFBundleIdentifier"] : nil) ?: @"(无 CFBundleIdentifier)";
                    NSMutableArray *bs = idsToBundles[bid];
                    if (!bs) { bs = [NSMutableArray array]; idsToBundles[bid] = bs; }
                    [bs addObject:app];
                }
                NSMutableArray<NSString *> *conflictLines = [NSMutableArray array];
                for (NSString *bid in idsToBundles) {
                    NSArray *bs = idsToBundles[bid];
                    if (bs.count > 1) {
                        [conflictLines addObject:[NSString stringWithFormat:
                            @"  • '%@' 被 [%@] 共用",
                            bid, [bs componentsJoinedByString:@", "]]];
                    }
                }
                if (conflictLines.count > 0) {
                    NSString *msg = [NSString stringWithFormat:
                        @"IPA 的 Payload 下多个 .app 共享同一 CFBundleIdentifier，installd 将拒装"
                        @"（MIInstallerErrorDomain code=181）。请先清理多余的 .app 后重新打包：\n%@",
                        [conflictLines componentsJoinedByString:@"\n"]];
                    if (error) {
                        *error = [self _errorFromString:msg errorCode:RPVErrorFailedToCopyBundle];
                    }
                    return NO;
                }
                // 多 .app 但 id 各不相同（少见但合法）：保留原行为取排序后首个，但要写日志
                // 让日后排查「我这里为什么签的是这一份」时能直接定位。
                NSLog(@"[ReSign] v2.2.4: Payload 下发现 %lu 个 .app 包，CFBundleIdentifier 各不相同，继续签名：%@",
                      (unsigned long)appBundles.count, appBundles.firstObject);
            }

            dotAppName = appBundles.firstObject;

            // Clear the downloaded IPA now that it is extracted properly.
            NSError *cacheClearError;
            [[NSFileManager defaultManager] removeItemAtPath:[application locationOfApplicationOnFilesystem].path error:&cacheClearError];

            if (cacheClearError) {
                NSLog(@"Failed to remove '%@'", [application locationOfApplicationOnFilesystem].path);
            }
        } else {
            if (error) {
                *error = [self _errorFromString:err.localizedDescription errorCode:RPVErrorFailedToCopyBundle];
            }
            return NO;
        }
    }

    *extractedArchiveURL = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/%@", temporaryDirectory, [application bundleIdentifier]]];
    *applicationBundleURL = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/%@/Payload/%@", temporaryDirectory, [application bundleIdentifier], dotAppName]];

    return YES;
}

- (NSError *)_errorFromString:(NSString *)string errorCode:(int)code {
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: NSLocalizedString(string, nil),
        NSLocalizedFailureReasonErrorKey: NSLocalizedString(string, nil),
        NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"", nil)
    };

    NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:code
                                     userInfo:userInfo];

    return error;
}

- (void)_initiateNextInstallFromQueueWithTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    if ([self.installQueue count] == 0) {
        // We can exit now.
        self.undertakingResignPipeline = NO;
    } else {
        // Pull next off the front of the array.
        RPVApplication *application = [self.installQueue firstObject];

        [self _resignApplication:application
                      withTeamID:teamID
                        username:username
                        password:password];
    }
}

// Register the signed app's provisioning profile with the system. On iOS 13/14 the
// on-device install registered the embedded profile automatically; on iOS 15+/rootless
// it does not, so the OS has no trusted profile for the app and rejects its signature
// ("failed to verify code signature" at install / instant AMFI kill at launch, and no
// entry in Settings > VPN & Device Management). This mirrors what Sideloadly/AltStore
// do as a separate step. Best-effort + heavily logged so we can confirm the exact API.

// Stable, unique filename for a provisioning profile derived from its content.
// profiled scans /var/Managed Preferences/mobile/*.mobileprovision regardless of
// the filename, so a content hash is sufficient and avoids parsing the CMS blob.
- (NSString *)_profileFileNameForData:(NSData *)data {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex stringByAppendingPathExtension:@"mobileprovision"];
}

// RootHide 专版：描述文件一律由 rootfs 上的 repro-profiledaemon 落盘 + 注册。
// sandbox 内的 App 直接写 /var/Managed Preferences/mobile 会落入 jbroot overlay，
// 而 profiled/installd 是系统自带 daemon，只读真实路径 —— overlay 副本它们看不见，
// 「写成功」是假成功，安装时照样 0xe8008015。所以这里不做任何直接写尝试。
- (BOOL)_registerProfileViaFileAtPath:(NSString *)profilePath {
    NSData *data = [NSData dataWithContentsOfFile:profilePath];
    if (data.length == 0) return NO;

    if (_rpvDaemonProfileInstallHandler) {
        BOOL ok = _rpvDaemonProfileInstallHandler(profilePath);
        RPVDiagnostic(ok ? RPVDiagInfo : RPVDiagError,
                      @"profile",
                      @"[RootHide] daemon profile install %@", ok ? @"succeeded" : @"failed");
        return ok;
    }

    RPVDiagnostic(RPVDiagError, @"profile",
                  @"[RootHide] 未挂载 root 安装通道，无法注册描述文件（请确认 repro-profiledaemon 已加载）");
    return NO;
}

- (BOOL)_registerProvisioningProfileAtPath:(NSString *)profilePath {
    // RootHide：App 进程在 jbroot namespace 内，in-process MCProfileConnection 的 XPC
    // 被重定向到 overlay profiled（返回 1 是假成功），写 /var/Managed Preferences/mobile
    // 也落 overlay —— installd（namespace 外）读不到，必 0xe8008015。
    // 故 RootHide 跳过 App MC，直接走 LaunchDaemon（repro-profiledaemon，系统级上下文、
    // 在 namespace 外）写真实路径并注册真实 profiled。
    RPVDiagnostic(RPVDiagInfo, @"profile",
                  @"[RootHide] 跳过 App 内 MC（namespace 内为假成功），走 repro-profiledaemon");
    return [self _registerProfileViaFileAtPath:profilePath];
}

- (void)_installIpaAtPath:(NSString *)ipaPath withBundleIdentifier:(NSString *)bundleIdentifier displayBundleIdentifier:(NSString *)displayBundleIdentifier {
    // bundleIdentifier is the *signed* id (with the Team ID suffix) - used for the
    // actual install/uninstall. displayBundleIdentifier is the id the UI tracks
    // progress under (the original, pre-signing id), so the progress bar reaches
    // 100% instead of getting stuck at 60%.
    if ([displayBundleIdentifier length] == 0) displayBundleIdentifier = bundleIdentifier;
    // v1.1.163：进入 install 时 +1（失败重试会先 -1 再递归，见下方），
    // 完成/失败时 -1 并检查是否全部 install 结束。
    @synchronized (self) { self.installCount++; }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error;
        NSDictionary *options = @{ @"CFBundleIdentifier": bundleIdentifier, @"AllowInstallLocalProvisioned": [NSNumber numberWithBool:YES] };

        NSURL *ipaURL = [NSURL fileURLWithPath:ipaPath];

        // Make a cached version of the .ipa for if we need to handle another go-around.
        [[NSFileManager defaultManager] copyItemAtPath:ipaPath toPath:[ipaPath stringByReplacingOccurrencesOfString:@".ipa" withString:@"2.ipa"] error:nil];

        NSLog(@"Does ipaPath exist? %d", [[NSFileManager defaultManager] fileExistsAtPath:ipaPath]);

        BOOL result = NO;
        @try {
            result = [[LSApplicationWorkspace defaultWorkspace] installApplication:ipaURL
                                                                       withOptions:options
                                                                             error:&error];
        } @catch (NSException *e) {
            error = [self _errorFromString:e.description errorCode:RPVErrorFailedToInstallSignedIPA];
            result = NO;
        }

        // 默认路径：LSApplicationWorkspace（< iOS 26 原生可用，参考 AltDaemonModern）。
        if (!result && error &&
            [error.domain isEqualToString:NSOSStatusErrorDomain] && error.code == -4 &&
            RPVSystemMajorVersion() >= 26) {
            // 「>iOS18版本 切换方案」：iOS 26 下 LS 被 stub（恒定 -4）→ 回退 InstallCoordination。
            RPVDiagnostic(RPVDiagInfo, @"install",
                          @"「>iOS18版本 切换方案」LS 返回 -4，回退 InstallCoordination");
            NSError *icError = nil;
            BOOL icOK = RPVBeginInstallWithInstallCoordination(ipaURL, bundleIdentifier, &icError);
            if (icOK) { result = YES; error = nil; }
            else if (icError) { error = icError; }
        }

        if (!result) {
            // Check if this is the case where it's an app from another Team ID.
            if (error.code == 64 || [error.localizedDescription containsString:@"LaunchServicesError error 0"]) {
                // Delete the original app, and try again.
                BOOL uninstalled = NO;
                // 「>iOS18版本 切换方案」：iOS 26 起 LS 卸载入口被 stub（恒定返回 NO），先走 LS，
                // 失败且 iOS>=26 时回退 MobileInstallationUninstall。
                uninstalled = [[LSApplicationWorkspace defaultWorkspace] uninstallApplication:bundleIdentifier withOptions:nil];
                RPVDiagnostic(uninstalled ? RPVDiagInfo : RPVDiagError, @"uninstall",
                              @"「>iOS18版本 切换方案」安装重试前卸载 bundleID=%@ → LS 返回 %@ (iOS major=%ld)",
                              bundleIdentifier, uninstalled ? @"YES" : @"NO", (long)RPVSystemMajorVersion());
                if (!uninstalled && RPVSystemMajorVersion() >= 26) {
                    NSError *miErr = nil;
                    uninstalled = RPVUninstallWithMobileInstallation(bundleIdentifier, &miErr);
                    RPVDiagnostic(uninstalled ? RPVDiagInfo : RPVDiagError, @"uninstall",
                                  @"「>iOS18版本 切换方案」安装重试前卸载 回退 MobileInstallation → %@ (err=%@)",
                                  uninstalled ? @"YES" : @"NO", miErr ? miErr.localizedDescription : @"nil");
                }
                if (uninstalled) {
                    // Try again!

                    // Update progress to 70% for this application.
                    for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                        [observer applicationSigningUpdateProgress:75 forBundleIdentifier:displayBundleIdentifier];
                    }

                    NSLog(@"*** Uninstalled application, trying again.");
                    // v1.1.163：重试是「替代」本次 install 而非新增 → 先 -1 再递归
                    @synchronized (self) { self.installCount--; }
                    [self _installIpaAtPath:[ipaPath stringByReplacingOccurrencesOfString:@".ipa" withString:@"2.ipa"] withBundleIdentifier:bundleIdentifier displayBundleIdentifier:displayBundleIdentifier];

                    return;
                }
            }

            // Build a full, faithful description of the installd error. The old
            // code tried to extract a "user friendly" substring (everything after
            // the last "("), which mangled iOS 16 errors into a useless set fragment
            // like ("com.foo.bar.TEAMID") and hid the real reason. Keep the friendly
            // mappings for known cases, but otherwise surface the raw error verbatim.
            NSString *rawDescription = error.localizedDescription ?: @"Unknown install error";
            NSString *fullError = [NSString stringWithFormat:@"%@ [%@ %ld]", rawDescription, error.domain ?: @"?", (long)error.code];

            // Pull underlying error / recovery details into the message too.
            NSString *underlying = [[error.userInfo objectForKey:NSUnderlyingErrorKey] localizedDescription];
            if ([underlying length] > 0) {
                fullError = [fullError stringByAppendingFormat:@" | underlying: %@", underlying];
            }

            // Show the raw installd error verbatim. (Older code tried to map known
            // codes to "friendly" text - including a wrong "3 app limit" message for
            // code 13 - which hid the real reason, so we just surface the truth.)
            NSString *errorMessage = fullError;

            RPVDiagnostic(RPVDiagError, @"install",
                          @"install failed: domain=%@ code=%ld desc=%@ userInfo=%@",
                          error.domain, (long)error.code, error.localizedDescription, error.userInfo);

            NSError *err = [self _errorFromString:errorMessage errorCode:RPVErrorFailedToInstallSignedIPA];
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningDidEncounterError:err forBundleIdentifier:displayBundleIdentifier];
            }
        }

        if (result) {
            // Update progress to 90% for this application.
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningUpdateProgress:90 forBundleIdentifier:displayBundleIdentifier];
            }
        }

        // Clean up.
        [[NSFileManager defaultManager] removeItemAtPath:ipaPath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:[ipaPath stringByReplacingOccurrencesOfString:@".ipa" withString:@"2.ipa"] error:nil];

        if (result) {
            // Update progress to 100% for this application.
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningUpdateProgress:100 forBundleIdentifier:displayBundleIdentifier];
            }
        }

        // 所有 install 都完成后（计数归零 + 流水线已结束）才通知 complete，且只发一次。
        // 🔴 v1.1.163：原逻辑只查 !undertakingResignPipeline —— 多 app 时倒数第二个的
        // 异步 install 先完成会误触发 complete，导致进程提前退出、后续 install 被打断。
        // 详见 _installIpaAtPath 顶部注释与 @interface 属性说明。
        @synchronized (self) { self.installCount--; }
        BOOL shouldComplete = NO;
        @synchronized (self) {
            if (!self.pipelineCompleteNotified &&
                self.installCount == 0 &&
                !self.undertakingResignPipeline) {
                self.pipelineCompleteNotified = YES;
                shouldComplete = YES;
            }
        }
        if (shouldComplete) {
            // End the background task!
            [[UIApplication sharedApplication] endBackgroundTask:self.currentBackgroundTaskIdentifier];
            self.currentBackgroundTaskIdentifier = UIBackgroundTaskInvalid;

            // Notify of success!
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:nil];
            }
        }
    });
}

- (void)_resignApplication:(RPVApplication *)application withTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    // Update progress to 10% for this application.
    for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
        [observer applicationSigningUpdateProgress:10 forBundleIdentifier:[application bundleIdentifier]];
    }

    //////////////////////////////////////////////////////////////////////////////////////
    // 1. Make a copy of this application's .app into a directory structure of an IPA.
    //////////////////////////////////////////////////////////////////////////////////////

    NSURL *extractedArchiveURL;   // This root directory is repacked into an IPA.
    NSURL *applicationBundleURL;  // Passed to EEbackend to sign (the .app).
    NSError *error;

    if (![self _copyApplicationBundleForApplication:application extractedArchiveURL:&extractedArchiveURL applicationBundleURL:&applicationBundleURL error:&error]) {
        // Callback to say we done "goofed".
        for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
            [observer applicationSigningDidEncounterError:error forBundleIdentifier:[application bundleIdentifier]];
        }

        // Start the next application off.
        if (self.installQueue.count > 1) {
            [self.installQueue removeObjectAtIndex:0];
            [self _initiateNextInstallFromQueueWithTeamID:teamID
                                                 username:username
                                                 password:password];
        } else {
            // End the background task!
            [[UIApplication sharedApplication] endBackgroundTask:self.currentBackgroundTaskIdentifier];
            self.currentBackgroundTaskIdentifier = UIBackgroundTaskInvalid;

            self.undertakingResignPipeline = NO;

            // Notify of failure
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:error];
            }
        }

        return;
    }

    // Update progress to 30% for this application.
    for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
        [observer applicationSigningUpdateProgress:30 forBundleIdentifier:[application bundleIdentifier]];
    }

    //////////////////////////////////////////////////////////////////////////////////////
    // 2. Use libProvision to sign the .app
    //////////////////////////////////////////////////////////////////////////////////////

    [EEBackend signBundleAtPath:[applicationBundleURL path] identity:username gsToken:password priorChosenTeamID:teamID withCompletionHandler:^(NSError *error) {
        if (error) {
            // Callback to say we done "goofed".
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningDidEncounterError:error forBundleIdentifier:[application bundleIdentifier]];
            }

            // TODO: Cleanup the filesystem?

            // Start the next application off.
            if (self.installQueue.count > 1) {
                [self.installQueue removeObjectAtIndex:0];
                [self _initiateNextInstallFromQueueWithTeamID:teamID
                                                     username:username
                                                     password:password];
            } else {
                // End the background task!
                [[UIApplication sharedApplication] endBackgroundTask:self.currentBackgroundTaskIdentifier];
                self.currentBackgroundTaskIdentifier = UIBackgroundTaskInvalid;

                self.undertakingResignPipeline = NO;

                // Notify of failure
                for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                    [observer applicationSigningCompleteWithError:error];
                }
            }

            return;
        }

        // Update progress to 50% for this application.
        for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
            [observer applicationSigningUpdateProgress:50 forBundleIdentifier:[application bundleIdentifier]];
        }

        // 诊断：验证签名后的 bundle 是否包含有效的 embedded.mobileprovision
        NSString *diagEmbeddedPath = [[applicationBundleURL path] stringByAppendingPathComponent:@"embedded.mobileprovision"];
        NSData *diagProfileData = [NSData dataWithContentsOfFile:diagEmbeddedPath];
        NSDictionary *diagInfoPlist = [NSDictionary dictionaryWithContentsOfFile:[[applicationBundleURL path] stringByAppendingPathComponent:@"Info.plist"]];
        NSLog(@"*** [ReProvision] === 签名后诊断 ===");
        NSLog(@"*** [ReProvision] signed bundle path: %@", [applicationBundleURL path]);
        NSLog(@"*** [ReProvision] embedded.mobileprovision exists: %d, size: %lu bytes",
              [[NSFileManager defaultManager] fileExistsAtPath:diagEmbeddedPath],
              (unsigned long)diagProfileData.length);
        NSLog(@"*** [ReProvision] signed CFBundleIdentifier: %@", [diagInfoPlist objectForKey:@"CFBundleIdentifier"]);
        NSLog(@"*** [ReProvision] extractedArchiveURL exists: %d", [[NSFileManager defaultManager] fileExistsAtPath:[extractedArchiveURL path]]);

        //////////////////////////////////////////////////////////////////////////////////////
        // 3. Build IPA
        //////////////////////////////////////////////////////////////////////////////////////

        NSString *outputIpaPath = [NSString stringWithFormat:@"%@/%@.ipa", [EEBackend applicationTemporaryDirectory], [application bundleIdentifier]];

        NSError *err;
        if (![EEBackend repackIpaAtPath:[extractedArchiveURL path] toPath:outputIpaPath error:&err]) {
            // Callback to say we done "goofed".
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningDidEncounterError:error forBundleIdentifier:[application bundleIdentifier]];
            }

            // TODO: Cleanup the filesystem?

            // Start the next application off.
            if (self.installQueue.count > 1) {
                [self.installQueue removeObjectAtIndex:0];
                [self _initiateNextInstallFromQueueWithTeamID:teamID
                                                     username:username
                                                     password:password];
            } else {
                // End the background task!
                [[UIApplication sharedApplication] endBackgroundTask:self.currentBackgroundTaskIdentifier];
                self.currentBackgroundTaskIdentifier = UIBackgroundTaskInvalid;

                self.undertakingResignPipeline = NO;

                // Notify of failure
                for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                    [observer applicationSigningCompleteWithError:error];
                }
            }

            return;
        }

        // Update progress to 60% for this application.
        for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
            [observer applicationSigningUpdateProgress:60 forBundleIdentifier:[application bundleIdentifier]];
        }

        //////////////////////////////////////////////////////////////////////////////////////
        // 4. Install IPA
        //////////////////////////////////////////////////////////////////////////////////////

        // libProvision appends the Team ID to the bundle id when signing (e.g.
        // com.opa334.Dopamine -> com.opa334.Dopamine.C9RTXQNQ3J). installd matches
        // the IPA against the CFBundleIdentifier install option, so we must pass the
        // *signed* id, not the original. Read it straight from the repacked app's
        // Info.plist; fall back to the original only if that read fails.
        NSString *bundleIdentifier = [application bundleIdentifier];
        NSString *signedInfoPlistPath = [[applicationBundleURL path] stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *signedInfoPlist = [NSDictionary dictionaryWithContentsOfFile:signedInfoPlistPath];
        NSString *signedBundleIdentifier = [signedInfoPlist objectForKey:@"CFBundleIdentifier"];
        if ([signedBundleIdentifier length] > 0) {
            bundleIdentifier = signedBundleIdentifier;
        }
        NSLog(@"*** [ReProvision] installing with bundle id '%@' (original '%@')", bundleIdentifier, [application bundleIdentifier]);

        // 诊断：确认待安装的 IPA 文件存在且非空
        NSDictionary *ipaAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outputIpaPath error:nil];
        NSLog(@"*** [ReProvision] === 安装前诊断 ===");
        NSLog(@"*** [ReProvision] IPA path: %@", outputIpaPath);
        NSLog(@"*** [ReProvision] IPA exists: %d, size: %@ bytes",
              [[NSFileManager defaultManager] fileExistsAtPath:outputIpaPath],
              [ipaAttrs objectForKey:NSFileSize]);

        // Register the freshly-signed provisioning profile with the system so iOS
        // trusts the signed app (misagent/MCProfileConnection). Without this the OS
        // refuses to launch the app even when the signature itself is valid.
        NSString *embeddedPath = [[applicationBundleURL path] stringByAppendingPathComponent:@"embedded.mobileprovision"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:embeddedPath]) {
            BOOL registered = [self _registerProvisioningProfileAtPath:embeddedPath];
            NSLog(@"*** [ReProvision] provisioning profile registered with system: %d", registered);
        }

        // Start the next application off at this point for some parallelism!
        if (self.installQueue.count > 1) {
            [self.installQueue removeObjectAtIndex:0];
            [self _initiateNextInstallFromQueueWithTeamID:teamID
                                                 username:username
                                                 password:password];
        } else {
            // Flag that we're done!
            self.undertakingResignPipeline = NO;
        }

        // And now we install! Install under the signed id, but report progress
        // under the original id that the UI is tracking.
        [self _installIpaAtPath:outputIpaPath withBundleIdentifier:bundleIdentifier displayBundleIdentifier:[application bundleIdentifier]];
    }];
}

////////////////////////////////////////////////////////////////////////////////
// Application handling callbacks
////////////////////////////////////////////////////////////////////////////////

- (BOOL)removeApplicationWithBundleIdentifier:(NSString *)bundleIdentifier {
    BOOL ret = NO;
    if (bundleIdentifier) {
        ret = [[LSApplicationWorkspace defaultWorkspace] uninstallApplication:bundleIdentifier withOptions:nil];
        RPVDiagnostic(ret ? RPVDiagInfo : RPVDiagError, @"uninstall",
                      @"「>iOS18版本 切换方案」removeApplication bundleID=%@ → LS 返回 %@ (iOS major=%ld)",
                      bundleIdentifier, ret ? @"YES" : @"NO", (long)RPVSystemMajorVersion());
        // 「>iOS18版本 切换方案」：iOS 26 LS 卸载被 stub（恒定返回 NO），回退 MobileInstallationUninstall。
        if (!ret && RPVSystemMajorVersion() >= 26) {
            NSError *miErr = nil;
            ret = RPVUninstallWithMobileInstallation(bundleIdentifier, &miErr);
            RPVDiagnostic(ret ? RPVDiagInfo : RPVDiagError, @"uninstall",
                          @"「>iOS18版本 切换方案」removeApplication 回退 MobileInstallation → %@ (err=%@)",
                          ret ? @"YES" : @"NO", miErr ? miErr.localizedDescription : @"nil");
        }
    }
    return ret;
}

- (void)_appShouldBeRemoved:(NSNotification *)notification {
    NSString *bundleIdentifier = [[notification userInfo] objectForKey:@"bundleIdentifier"];
    if (bundleIdentifier) {
        // 「>iOS18版本 切换方案」：iOS 26 起 LS 卸载入口被 stub（恒定返回 NO），先走 LS，
        // 失败且 iOS>=26 时回退 MobileInstallationUninstall（与另两处卸载点对齐，v2.2.8 补齐）。
        BOOL ok = [[LSApplicationWorkspace defaultWorkspace] uninstallApplication:bundleIdentifier withOptions:nil];
        RPVDiagnostic(ok ? RPVDiagInfo : RPVDiagError, @"uninstall",
                      @"「>iOS18版本 切换方案」_appShouldBeRemoved bundleID=%@ → LS 返回 %@ (iOS major=%ld)",
                      bundleIdentifier, ok ? @"YES" : @"NO", (long)RPVSystemMajorVersion());
        if (!ok && RPVSystemMajorVersion() >= 26) {
            NSError *miErr = nil;
            ok = RPVUninstallWithMobileInstallation(bundleIdentifier, &miErr);
            RPVDiagnostic(ok ? RPVDiagInfo : RPVDiagError, @"uninstall",
                          @"「>iOS18版本 切换方案」_appShouldBeRemoved 回退 MobileInstallation → %@ (err=%@)",
                          ok ? @"YES" : @"NO", miErr ? miErr.localizedDescription : @"nil");
        }
    }
}

@end
