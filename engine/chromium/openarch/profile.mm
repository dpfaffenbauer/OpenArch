// OACProfile on Chrome's framework: a Chrome Profile, loaded through
// Chrome's ProfileManager.

#include "openarch/internal.h"

#include <map>
#include <memory>
#include <string>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/logging.h"
#include "base/values.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/storage_partition.h"
#include "net/base/net_errors.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "openarch/internal.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/gurl.h"

namespace {

NSMutableDictionary<NSString*, OACProfile*>* g_profiles = nil;
NSMutableDictionary<NSString*, id>* g_preferences = nil;

constexpr net::NetworkTrafficAnnotationTag kFetchAnnotation =
    net::DefineNetworkTrafficAnnotation("openarch_fetch", R"(
      semantics {
        sender: "OpenArch"
        description: "Downloads a resource OpenArch's own UI asked for."
        trigger: "OpenArch's UI."
        data: "None."
        destination: OTHER
      }
      policy {
        cookies_allowed: YES
        setting: "None."
        policy_exception_justification: "Embedder fetch."
      })");

ContentSettingsType ContentType(OACSitePermission permission) {
  switch (permission) {
    case OACSitePermissionCamera:
      return ContentSettingsType::MEDIASTREAM_CAMERA;
    case OACSitePermissionMicrophone:
      return ContentSettingsType::MEDIASTREAM_MIC;
    case OACSitePermissionLocation:
      return ContentSettingsType::GEOLOCATION;
    case OACSitePermissionNotifications:
      return ContentSettingsType::NOTIFICATIONS;
    case OACSitePermissionPopups:
      return ContentSettingsType::POPUPS;
    case OACSitePermissionSound:
      return ContentSettingsType::SOUND;
    case OACSitePermissionAutomaticDownloads:
      return ContentSettingsType::AUTOMATIC_DOWNLOADS;
    case OACSitePermissionClipboard:
      return ContentSettingsType::CLIPBOARD_READ_WRITE;
    case OACSitePermissionJavaScript:
      return ContentSettingsType::JAVASCRIPT;
  }
}

std::optional<base::Value> ToValue(id value) {
  if ([value isKindOfClass:[NSString class]]) {
    return base::Value(openarch::ToStdString(value));
  }
  if ([value isKindOfClass:[NSNumber class]]) {
    NSNumber* number = value;
    if (strcmp(number.objCType, @encode(BOOL)) == 0 || strcmp(number.objCType, "c") == 0) {
      return base::Value(number.boolValue);
    }
    if (strcmp(number.objCType, @encode(double)) == 0 ||
        strcmp(number.objCType, @encode(float)) == 0) {
      return base::Value(number.doubleValue);
    }
    return base::Value(number.intValue);
  }
  return std::nullopt;
}

void ApplyPreference(Profile* profile, NSString* name, id value) {
  PrefService* prefs = profile->GetPrefs();
  std::string key = openarch::ToStdString(name);
  const PrefService::Preference* pref = prefs->FindPreference(key);
  if (!pref || !pref->IsUserModifiable()) {
    LOG(WARNING) << "[openarch] preference " << key << " is unknown or not user-modifiable";
    return;
  }
  std::optional<base::Value> converted = ToValue(value);
  if (!converted) {
    LOG(WARNING) << "[openarch] preference " << key << ": unsupported value";
    return;
  }
  prefs->Set(key, *converted);
}

}  // namespace

@implementation OACProfile {
  raw_ptr<Profile> _profile;
  std::unique_ptr<ScopedProfileKeepAlive> _keepAlive;
  BOOL _private;
  BOOL _loading;
  NSMutableArray<dispatch_block_t>* _readyBlocks;
  NSMutableArray* _profileBlocks;
}

+ (OACProfile*)defaultProfile {
  return [self profileWithDirectoryName:@"Default"];
}

+ (OACProfile*)profileWithDirectoryName:(NSString*)directoryName {
  if (!g_profiles) {
    g_profiles = [NSMutableDictionary dictionary];
  }
  OACProfile* profile = g_profiles[directoryName];
  if (!profile) {
    profile = [[OACProfile alloc] initWithDirectoryName:directoryName isPrivate:NO];
    g_profiles[directoryName] = profile;
  }
  return profile;
}

+ (OACProfile*)makePrivateProfile {
  return [[OACProfile alloc]
      initWithDirectoryName:@""
                  isPrivate:YES];
}

- (instancetype)initWithDirectoryName:(NSString*)directoryName isPrivate:(BOOL)isPrivate {
  if ((self = [super init])) {
    _directoryName = [directoryName copy];
    _private = isPrivate;
    _readyBlocks = [NSMutableArray array];
    _profileBlocks = [NSMutableArray array];
    if (openarch::IsReady()) {
      [self withChromeProfile:^(Profile*) {
      }];
    } else {
      __weak OACProfile* weakSelf = self;
      [OACEngine whenReady:^{
        [weakSelf withChromeProfile:^(Profile*) {
        }];
      }];
    }
  }
  return self;
}

- (BOOL)isReady {
  return _profile != nullptr;
}

- (NSString*)cachePath {
  if (!_profile || _private) {
    return @"";
  }
  return openarch::ToNSString(_profile->GetPath().value());
}

- (void)whenReady:(dispatch_block_t)block {
  if (_profile) {
    block();
    return;
  }
  [_readyBlocks addObject:[block copy]];
}

- (Profile*)chromeProfile {
  return _profile;
}

- (void)withChromeProfile:(void (^)(Profile*))block {
  if (_profile) {
    block(_profile);
    return;
  }
  [_profileBlocks addObject:[block copy]];
  if (_loading || !openarch::IsReady()) {
    return;
  }
  _loading = YES;
  ProfileManager* manager = g_browser_process->profile_manager();
  if (_private) {
    __weak OACProfile* weakSelf = self;
    [[OACProfile defaultProfile] withChromeProfile:^(Profile* original) {
      Profile* incognito = original
          ? original->GetOffTheRecordProfile(
                Profile::OTRProfileID::CreateUnique("OpenArch::Private"),
                /*create_if_needed=*/true)
          : nullptr;
      [weakSelf profileLoaded:incognito];
    }];
    return;
  }
  base::FilePath path = manager->user_data_dir().Append(openarch::ToStdString(_directoryName));
  if (Profile* loaded = manager->GetProfileByPath(path)) {
    [self profileLoaded:loaded];
    return;
  }
  __weak OACProfile* weakSelf = self;
  manager->CreateProfileAsync(path, base::BindOnce(^(Profile* profile) {
                                [weakSelf profileLoaded:profile];
                              }));
}

- (void)profileLoaded:(Profile*)profile {
  _loading = NO;
  _profile = profile;
  if (profile && !profile->IsOffTheRecord()) {
    // OpenArch's pages live in a hidden window; the profile stays loaded
    // while OpenArch runs, as it would with a window open in Chrome.
    _keepAlive = std::make_unique<ScopedProfileKeepAlive>(
        profile, ProfileKeepAliveOrigin::kBrowserWindow);
  }
  if (profile) {
    for (NSString* name in g_preferences) {
      ApplyPreference(profile, name, g_preferences[name]);
    }
  }
  NSArray* profileBlocks = [_profileBlocks copy];
  [_profileBlocks removeAllObjects];
  for (void (^block)(Profile*) in profileBlocks) {
    block(profile);
  }
  if (profile) {
    NSArray<dispatch_block_t>* readyBlocks = [_readyBlocks copy];
    [_readyBlocks removeAllObjects];
    for (dispatch_block_t block in readyBlocks) {
      block();
    }
  }
}

- (void)fetchURL:(NSString*)url completion:(void (^)(NSData*, NSInteger))completion {
  [self fetchURL:url headers:@{} completion:completion];
}

- (void)fetchURL:(NSString*)url
         headers:(NSDictionary<NSString*, NSString*>*)headers
      completion:(void (^)(NSData*, NSInteger))completion {
  void (^done)(NSData*, NSInteger) = [completion copy];
  [self withChromeProfile:^(Profile* profile) {
    if (!profile) {
      done(nil, 0);
      return;
    }
    auto request = std::make_unique<network::ResourceRequest>();
    request->url = GURL(openarch::ToStdString(url));
    request->credentials_mode = network::mojom::CredentialsMode::kInclude;
    for (NSString* name in headers) {
      request->headers.SetHeader(openarch::ToStdString(name),
                                 openarch::ToStdString(headers[name]));
    }
    auto loader = network::SimpleURLLoader::Create(std::move(request), kFetchAnnotation);
    network::SimpleURLLoader* raw = loader.get();
    auto factory = profile->GetDefaultStoragePartition()->GetURLLoaderFactoryForBrowserProcess();
    raw->DownloadToStringOfUnboundedSizeUntilCrashAndDie(
        factory.get(),
        base::BindOnce(
            ^(std::unique_ptr<network::SimpleURLLoader> owned, std::optional<std::string> body) {
              NSInteger status = 0;
              if (owned->ResponseInfo() && owned->ResponseInfo()->headers) {
                status = owned->ResponseInfo()->headers->response_code();
              }
              done(body ? [NSData dataWithBytes:body->data() length:body->size()] : nil, status);
            },
            std::move(loader)));
  }];
}

- (OACPermissionValue)permission:(OACSitePermission)permission forSite:(NSString*)url {
  if (!_profile) {
    return OACPermissionValueDefault;
  }
  HostContentSettingsMap* map = HostContentSettingsMapFactory::GetForProfile(_profile);
  GURL site(openarch::ToStdString(url));
  content_settings::SettingInfo info;
  ContentSetting setting =
      map->GetContentSetting(site, site, ContentType(permission), &info);
  if (info.source != content_settings::SettingSource::kUser ||
      info.primary_pattern.MatchesAllHosts()) {
    return OACPermissionValueDefault;
  }
  switch (setting) {
    case CONTENT_SETTING_ALLOW:
      return OACPermissionValueAllow;
    case CONTENT_SETTING_BLOCK:
      return OACPermissionValueBlock;
    case CONTENT_SETTING_ASK:
      return OACPermissionValueAsk;
    default:
      return OACPermissionValueDefault;
  }
}

- (void)setPermission:(OACSitePermission)permission
              forSite:(NSString*)url
                value:(OACPermissionValue)value {
  ContentSetting setting = CONTENT_SETTING_DEFAULT;
  switch (value) {
    case OACPermissionValueAllow:
      setting = CONTENT_SETTING_ALLOW;
      break;
    case OACPermissionValueBlock:
      setting = CONTENT_SETTING_BLOCK;
      break;
    case OACPermissionValueAsk:
      setting = CONTENT_SETTING_ASK;
      break;
    case OACPermissionValueDefault:
      break;
  }
  [self withChromeProfile:^(Profile* profile) {
    if (!profile) {
      return;
    }
    GURL site(openarch::ToStdString(url));
    HostContentSettingsMapFactory::GetForProfile(profile)->SetContentSettingDefaultScope(
        site, site, ContentType(permission), setting);
  }];
}

+ (void)setPreference:(NSString*)name value:(id)value {
  if (!g_preferences) {
    g_preferences = [NSMutableDictionary dictionary];
  }
  g_preferences[name] = value;
  for (OACProfile* profile in g_profiles.allValues) {
    if (profile->_profile) {
      ApplyPreference(profile->_profile, name, value);
    }
  }
}

@end
