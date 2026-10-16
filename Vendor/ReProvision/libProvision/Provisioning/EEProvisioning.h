//
//  EEProvisioning.h
//  OpenExtenderTest
//
//  Created by Matt Clarke on 28/12/2017.
//  Copyright © 2017 Matt Clarke. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "EEAppleServices.h"

@interface EEProvisioning : NSObject {
    NSString *_identity;
    NSString *_gsToken;
}

/**
 Creates a new instance of EEProvisioning with the given credentials.
 Note: if using 2-Factor Authentication, make sure to generate an App-Specific password
 
 @param identity The DSIS identity to sign in to Apple developer with.
 @param gsToken The GS token associated with the identity.
 */
+ (instancetype)provisionerWithCredentials:(NSString*)identity :(NSString*)gsToken;

/**
 Adds the current device to Apple's Developer portal for the current team. It is likely this should only need
 to be called once, such as when validating user credentials.
 
 @param completionHandler The block called once the operation is complete.
 
 In the completionHandler, the first value is a success indicator. The second is the result; if success is NO,
 then this shall be the associated error message.
 */
- (void)provisionDevice:(NSString*)udid name:(NSString*)name withTeamIDCheck:(NSString* (^)(NSArray*))teamIDCallback systemType:(EESystemType)systemType  andCallback:(void (^)(NSError*))completionHandler;

/** TODO: Docs!
 */
- (void)revokeCertificatesWithTeamIDCheck:(NSString* (^)(NSArray*))teamIDCallback systemType:(EESystemType)systemType andCallback:(void (^)(NSError*))completionHandler;

/**
 幂等地把指定 UDID 注册到当前 team 的 Apple DevPortal 设备列表（v2.2.6 新增）。
 登录流程的 registerCurrentDeviceForTeamID 错误被上层无条件吞掉，换设备/新账号首次
 重签时 profile 的 ProvisionedDevices 不含本机 → 签名成功但安装 0xe8008015。
 本方法：stage1 登录 → listDevices 查 UDID 是否已在 → 已在不动作（幂等），不在则
 addDevice 注册。任何一步失败回调 error（含免费账号设备数上限等真实原因），
 由调用方决定是否中止签名。

 @param udid 本机 UDID（UniqueDeviceID）。
 @param name 注册用的设备名（任意可读字符串即可）。
 @param teamId 目标 team。
 @param completionHandler 完成回调；error 非空表示注册失败。
 */
- (void)ensureCurrentDeviceRegistered:(NSString*)udid deviceName:(NSString*)name teamId:(NSString*)teamId withCallback:(void (^)(NSError*))completionHandler;

/**
 Does all the hard work behind-the-scenes work to download a provisioning profile for a given application.
 
 @param identifier The bundle identifier of the application to provision.
 @param completionHandler The block called once the provisioning profile is downloaded.
 
 In the completionHandler, the first value is a success indicator. The second is the result; if success is NO,
 then this shall be the associated error message. If YES, then it is the profile, and the third is the development
 certificate to sign binaries with.
 */
- (void)downloadProvisioningProfileForApplicationIdentifier:(NSString*)identifier applicationName:(NSString*)applicationName binaryLocation:(NSString*)binaryLocation withTeamIDCheck:(NSString* (^)(NSArray*))teamIDCallback systemType:(EESystemType)systemType andCallback:(void (^)(NSError *, NSData*, NSString*, NSDictionary*, NSDictionary*))completionHandler;

@end
